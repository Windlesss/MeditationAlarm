import Foundation
import HealthKit
import SwiftData

/// 体征采样器（第三阶段 v3a）。
///
/// **三层叠加**（REQUIREMENTS D4.2）—— 单靠定时器轮询会漏数据：
/// 1. **`HKAnchoredObjectQuery`（主）**：会话开始时建立，先捞会话起点至今的存量
///    样本，之后手表写入新样本的**即刻回调**，零延迟；
/// 2. **`HKObserverQuery` + 后台 delivery（补）**：App 被挂起时（如暂停中的会话
///    退后台），新样本写入会唤醒 App 补录；
/// 3. **30s 兜底轮询（保底）**：前两层漏掉时兜回来。App 活着时基本是保险丝。
///
/// 所有样本灌入 `VitalsBook` 按 HealthKit 样本 uuid 去重后落 SwiftData ——
/// 一条真实样本在图上只有一个点，不去重会画出虚假平线。
///
/// 无开关、无配置（用户 2026-10-20 决策）：授权由 `HealthKitService` 在首次
/// 会话开始时代为请求；未授权时查询静默返回空，授权后数据自然流入。
@MainActor
final class VitalSampler {

    static let shared = VitalSampler()

    private let store = HKHealthStore()

    /// 采样中的会话。nil = 未采样。
    private var recordID: UUID?
    private var sessionStart: Date?

    /// 去重簿。跨启动恢复时用库里已有的去重键预热，防止重复入库。
    private var book = VitalsBook()

    private var anchoredQueries: [HKAnchoredObjectQuery] = []
    private var observerQueries: [HKObserverQuery] = []
    private var fallbackTimer: DispatchSourceTimer?

    /// 兜底轮询的私有队列（与音频调度链同思路：脱离主 RunLoop）。
    private let timerQueue = DispatchQueue(
        label: "com.windlessd.MeditationAlarm.vitals",
        qos: .utility
    )

    /// 兜底轮询间隔。仅影响第 3 层，主链路是即时回调（用户 2026-10-20 决策：
    /// 不做配置 UI，固定 30s）。
    private let fallbackInterval: TimeInterval = 30

    private init() {}

    var isSampling: Bool { recordID != nil }

    // MARK: 采样类型

    private var sampleTypes: [HKSampleType] {
        [
            HKQuantityType(.heartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
        ].compactMap { $0 }
    }

    private var quantityTypes: [HKQuantityType] {
        [
            HKQuantityType.quantityType(forIdentifier: .heartRate),
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
        ].compactMap { $0 }
    }

    // MARK: 生命周期

    /// 开始采样。幂等 —— 重复调用先停掉旧的。
    /// - Parameters:
    ///   - recordID: 本次会话对应的 `SessionRecord.id`（样本挂到它名下）
    ///   - sessionStart: 会话开始时刻。查询带 60s 前探缓冲（手表写入时刻可能
    ///     略晚于测量时刻），窗口外的样本由 `VitalsBook.presentation` 过滤掉。
    func start(recordID: UUID, sessionStart: Date) {
        stop()
        guard HKHealthStore.isHealthDataAvailable() else {
            dbgLog("[vitals] HealthKit unavailable, sampling disabled")
            return
        }
        self.recordID = recordID
        self.sessionStart = sessionStart
        self.book = VitalsBook()
        prewarmFromStore()

        startAnchoredQueries()
        startObserverQueries()
        startFallbackTimer()
        dbgLog("[vitals] sampling started, record = \(recordID)")
    }

    /// 停止采样。取消全部查询与后台 delivery。已入库的样本不受影响。
    func stop() {
        guard recordID != nil else { return }
        for query in anchoredQueries { store.stop(query) }
        for query in observerQueries { store.stop(query) }
        anchoredQueries.removeAll()
        observerQueries.removeAll()

        fallbackTimer?.cancel()
        fallbackTimer = nil

        for type in quantityTypes {
            store.disableBackgroundDelivery(for: type) { _, _ in }
        }

        dbgLog("[vitals] sampling stopped, record = \(String(describing: recordID))")
        recordID = nil
        sessionStart = nil
    }

    // MARK: 第 1 层：Anchored 主查询

    private func startAnchoredQueries() {
        guard let sessionStart else { return }
        // 手表样本的 startDate 是测量时刻，写入可能稍晚 —— 前探 60s 缓冲，
        // 窗口外的样本在 presentation 投影时剔除
        let predicate = HKQuery.predicateForSamples(
            withStart: sessionStart.addingTimeInterval(-60),
            end: nil,
            options: []
        )

        for type in quantityTypes {
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: nil,
                limit: HKObjectQueryNoLimit
            ) { [weak self] (
                _: HKAnchoredObjectQuery,
                samples: [HKSample]?,
                _: [HKDeletedObject]?,
                _: HKQueryAnchor?,
                error: Error?
            ) in
                if let error {
                    dbgLog("[vitals] anchored initial error: \(error)")
                    return
                }
                Task { @MainActor in self?.ingest(samples ?? []) }
            }
            query.updateHandler = { [weak self] (
                _: HKAnchoredObjectQuery,
                samples: [HKSample]?,
                _: [HKDeletedObject]?,
                _: HKQueryAnchor?,
                error: Error?
            ) in
                if let error {
                    dbgLog("[vitals] anchored update error: \(error)")
                    return
                }
                Task { @MainActor in self?.ingest(samples ?? []) }
            }
            anchoredQueries.append(query)
            store.execute(query)
        }
    }

    // MARK: 第 2 层：Observer 后台补录

    private func startObserverQueries() {
        for type in quantityTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                if let error {
                    dbgLog("[vitals] observer error: \(error)")
                }
                // 被唤醒（含后台 delivery）：立即兜底拉一遍会话窗口（去重兜住重复）。
                // 注意不能对已有 anchored query 二次 execute —— HealthKit 会抛
                // NSException（2026-10-20 模拟器实测 SIGABRT）；即时回调由
                // anchored 的 updateHandler 常驻负责，这里只做补录。
                Task { @MainActor in
                    self?.pollFallback()
                    completion()
                }
            }
            observerQueries.append(query)
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { success, error in
                if let error {
                    dbgLog("[vitals] background delivery error: \(error)")
                } else {
                    dbgLog("[vitals] background delivery enabled for \(type.identifier): \(success)")
                }
            }
        }
    }

    // MARK: 第 3 层：兜底轮询

    private func startFallbackTimer() {
        fallbackTimer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(
            deadline: .now() + fallbackInterval,
            repeating: fallbackInterval,
            leeway: .seconds(1)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.pollFallback() }
        }
        fallbackTimer = source
        source.resume()
    }

    /// 兜底轮询：全量拉一遍会话窗口，去重后只剩没入库的新样本。
    private func pollFallback() {
        guard let sessionStart else { return }
        let predicate = HKQuery.predicateForSamples(
            withStart: sessionStart.addingTimeInterval(-60),
            end: nil,
            options: []
        )
        for type in quantityTypes {
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { [weak self] _, samples, error in
                if let error {
                    dbgLog("[vitals] fallback poll error: \(error)")
                    return
                }
                Task { @MainActor in self?.ingest(samples ?? []) }
            }
            store.execute(query)
        }
    }

    // MARK: 入库

    /// 把 HealthKit 样本转成 `VitalReading`，去重后落 SwiftData。
    private func ingest(_ samples: [HKSample]) {
        guard recordID != nil, !samples.isEmpty else { return }
        var newReadings: [VitalReading] = []
        for sample in samples {
            guard let quantity = sample as? HKQuantitySample else { continue }
            let reading: VitalReading
            switch quantity.quantityType.identifier {
            case HKQuantityTypeIdentifier.heartRate.rawValue:
                reading = VitalReading(
                    kind: .heartRate,
                    value: quantity.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                    startDate: quantity.startDate,
                    endDate: quantity.endDate,
                    sourceID: quantity.uuid.uuidString
                )
            default:
                reading = VitalReading(
                    kind: .hrvSDNN,
                    value: quantity.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli)),
                    startDate: quantity.startDate,
                    endDate: quantity.endDate,
                    sourceID: quantity.uuid.uuidString
                )
            }
            if book.ingest(reading) { newReadings.append(reading) }
        }
        persist(newReadings)
    }

    private func persist(_ readings: [VitalReading]) {
        guard !readings.isEmpty, let recordID else { return }
        let context = SessionStore.container.mainContext
        let descriptor = FetchDescriptor<SessionRecord>()
        guard let record = (try? context.fetch(descriptor))?.first(where: { $0.id == recordID }) else {
            dbgLog("[vitals] persist skipped: record \(recordID) not found")
            return
        }
        for reading in readings {
            let row = VitalRecord(reading: reading)
            row.session = record
            context.insert(row)
        }
        do {
            try context.save()
            dbgLog("[vitals] persisted \(readings.count) new sample(s)")
        } catch {
            dbgLog("[vitals] persist FAILED: \(error)")
        }
    }

    /// 用库里**全部**已有去重键预热（不只是本会话的）：
    /// 双 start / 恢复竞态下同一条样本可能落入两个会话窗口，
    /// 而 `dedupeKey` 是全局唯一索引 —— 完整性优先，第二个会话不重复收。
    private func prewarmFromStore() {
        let descriptor = FetchDescriptor<VitalRecord>()
        let existing = (try? SessionStore.container.mainContext.fetch(descriptor)) ?? []
        book.prewarm(keys: existing.map(\.dedupeKey))
        if !existing.isEmpty {
            dbgLog("[vitals] prewarmed \(existing.count) existing dedupe key(s)")
        }
    }
}
