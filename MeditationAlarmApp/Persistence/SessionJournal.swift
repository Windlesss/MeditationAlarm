import Foundation
import SwiftData

/// 冥想记录的写入服务（第二阶段，用户 2026-10-20 决策）。
///
/// 设计原则——**「setup 是 setup，记录是记录」**：结束流程（`SessionController.end`）
/// 只负责把结算数据交给这里，不关心「记不记」；记录与否的决策是独立的：
/// - 实际时长 ≥ 阈值 → 静默落库；
/// - 低于阈值 → 撤回已写的记录，挂起 `pendingConfirmation` 等用户决定
///   （UI 层弹「记录 / 不记录」，默认记录）。
///
/// 同时承担**跨启动恢复**：`begin` 写的 open 记录（`endedAt == nil`）带时钟快照，
/// App 被杀后重启时 `unfinishedRecord()` 供 `SessionController.restoreIfNeeded` 还原会话。
@MainActor
@Observable
final class SessionJournal {

    static let shared = SessionJournal()

    #if DEBUG
    /// 短会话阈值（秒）。低于它结束时要问「是否记录」。
    /// 测试期 60s：selfTest 的 35 秒会话正好能验证弹框；正式 180s（3 分钟）。
    static let recordThreshold: TimeInterval = 60
    #else
    static let recordThreshold: TimeInterval = 180
    #endif

    private let context: ModelContext

    /// 结束走完、时长低于阈值时挂起的待确认记录。UI 观察此属性弹框。
    private(set) var pendingConfirmation: PendingSession?

    /// 最近一条闭合且可能携带健康数据的记录。UI 观察它呈现小结页，
    /// 展示后调 `clearLastClosed` 清空。仅在有健康数据时才值得呈现 ——
    /// 由 UI 层判断（record.vitals 非空）。
    private(set) var lastClosedRecordID: UUID?

    func clearLastClosed() {
        lastClosedRecordID = nil
    }

    /// 待确认的草稿。`recordID` 指向那条已被标记作废的开放记录 ——
    /// 用户选「记录」时把它写活（改属性），不新建、不删除。
    struct PendingSession: Equatable {
        var recordID: UUID
        var startedAt: Date
        var seconds: TimeInterval
        var reasonRaw: String
        var plannedDuration: TimeInterval?
        var interval: TimeInterval?
        var chimeID: String
        var endChimeID: String
        var ambientID: String?
        var wasAutoAdjusted: Bool
    }

    private init() {
        context = SessionStore.container.mainContext
    }

    // MARK: 会话生命周期

    /// 开始时建 open 记录。结束前它一直带着最新时钟快照。
    /// - Returns: 新建的记录 —— 调用方需要 `id` 与 `startedAt` 给健康采样器挂钩子。
    @discardableResult
    func begin(configuration: SessionController.Configuration) -> SessionRecord {
        // 防御：开新会话前若还有 open 记录，说明是异常残留（历史撤回失败、
        // 双 start 竞态）。先闭合为作废 —— 绝不留永驻空壳被恢复逻辑误判。
        if let stale = openRecord() {
            stale.endedAt = Date()
            stale.endReason = "discarded"
            stale.isDiscarded = true
            stale.segmentStart = nil
            stale.segments = nil
            save()
            dbgLog("[journal] closed stale open record \(stale.id)")
        }
        let record = SessionRecord(
            startedAt: Date(),
            plannedDuration: configuration.plannedDuration,
            interval: configuration.interval,
            wasAutoAdjusted: configuration.wasAutoAdjusted,
            chimeID: configuration.chimeID,
            endChimeID: configuration.endChimeID,
            ambientID: configuration.ambientID,
            chimeVolume: configuration.chimeVolume,
            ambientVolume: configuration.ambientVolume
        )
        context.insert(record)
        save()
        return record
    }

    /// 暂停 / 继续时把时钟快照写进 open 记录 —— App 被杀后靠它恢复。
    func checkpoint(_ clock: SessionClock) {
        guard let record = openRecord() else { return }
        record.accumulated = clock.accumulated
        record.segmentStart = clock.segmentStart
        record.segments = try? JSONEncoder().encode(clock.finishedSegments)
        save()
    }

    /// 结束结算。够长 → 静默落库；不够 → 记录标记作废、挂起等用户决定。
    func finish(reason: SessionController.EndReason, segments: [TimedSegment]) {
        guard let record = openRecord() else { return }
        let seconds = segments.reduce(0) { $0 + $1.duration }
        let reasonRaw = reason == .natural ? "natural" : "manual"

        // segments 保留不清零：正念写入（含前台重试）要靠它还原区间。
        // open 记录的恢复逻辑只认 endedAt == nil 的记录，留着无副作用。
        record.segments = try? JSONEncoder().encode(segments)

        if seconds >= Self.recordThreshold {
            // 够长：正常闭合
            record.endedAt = Date()
            record.billableSeconds = seconds
            record.endReason = reasonRaw
            record.isDiscarded = false
            record.accumulated = 0
            record.segmentStart = nil
            save()
            lastClosedRecordID = record.id
            // 正念写入承接记录逻辑（用户 2026-10-20 决策）：这条记录成立了 → 写健康 App
            scheduleMindfulWrite(recordID: record.id, segments: segments)
        } else {
            // 不够：先闭合但标记作废（撤回靠 delete 不可靠，见字段注释），
            // 挂起待确认；用户选「记录」再把同一条写活
            record.endedAt = Date()
            record.billableSeconds = 0
            record.endReason = "discarded"
            record.isDiscarded = true
            record.accumulated = 0
            record.segmentStart = nil
            save()
            pendingConfirmation = PendingSession(
                recordID: record.id,
                startedAt: record.startedAt,
                seconds: seconds,
                reasonRaw: reasonRaw,
                plannedDuration: record.plannedDuration,
                interval: record.interval,
                chimeID: record.chimeID,
                endChimeID: record.endChimeID,
                ambientID: record.ambientID,
                wasAutoAdjusted: record.wasAutoAdjusted
            )
        }
    }

    /// 用户在弹框里选「记录」—— 把作废的同一记录写活（不新建、不删除）。
    func commitPending() {
        guard let pending = pendingConfirmation else { return }
        if let record = record(id: pending.recordID) {
            record.billableSeconds = pending.seconds
            record.endReason = pending.reasonRaw
            record.isDiscarded = false
            save()
            lastClosedRecordID = record.id
            // 承接记录逻辑：用户选了「记录」→ 这条成立 → 写健康 App
            let segments = record.segments.flatMap {
                try? JSONDecoder().decode([TimedSegment].self, from: $0)
            } ?? []
            scheduleMindfulWrite(recordID: record.id, segments: segments)
        }
        pendingConfirmation = nil
    }

    /// 用户在弹框里选「不记录」—— 记录保持作废状态留在库里，不进任何展示。
    /// 作废记录**不写**健康 App（用户 2026-10-20 决策）。
    func discardPending() {
        pendingConfirmation = nil
    }

    // MARK: 正念分钟数写入（第三阶段 v3a）

    /// 触发一次正念写入。fire-and-forget：成功回写 `mindfulWritten` 标记，
    /// 失败留给前台重试。写授权状态不可重试判断（读的不可查、写的可查），
    /// 未授权时 `HealthKitService` 直接返回 false。
    private func scheduleMindfulWrite(recordID: UUID, segments: [TimedSegment]) {
        Task { @MainActor in
            let written = await HealthKitService.shared.writeMindfulSession(segments: segments)
            if written, let record = record(id: recordID) {
                record.mindfulWritten = true
                save()
            }
        }
    }

    /// 前台重试：被拒 / 写失败的正念写入，在用户改主意去设置里授权后补写。
    /// 每次前台只处理未完成的闭合记录（作废的不写）。
    func retryMindfulWrites() {
        let descriptor = FetchDescriptor<SessionRecord>(
            predicate: #Predicate<SessionRecord> {
                $0.endedAt != nil && !$0.isDiscarded && !$0.mindfulWritten
            }
        )
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }
        dbgLog("[journal] retrying mindful writes for \(pending.count) record(s)")
        for record in pending {
            let segments = record.segments.flatMap {
                try? JSONDecoder().decode([TimedSegment].self, from: $0)
            } ?? []
            scheduleMindfulWrite(recordID: record.id, segments: segments)
        }
    }

    // MARK: 健康数据查询（UI 与采样器共用）

    /// 某条记录的全部体征样本（按时间排序）。
    func vitals(for recordID: UUID) -> [VitalRecord] {
        guard let record = record(id: recordID) else { return [] }
        return record.vitals.sorted { $0.startDate < $1.startDate }
    }

    /// 最新一条闭合且未作废的记录（调试后门直接开小结页用）。
    func latestClosedRecord() -> SessionRecord? {
        let descriptor = FetchDescriptor<SessionRecord>(
            predicate: #Predicate<SessionRecord> { $0.endedAt != nil && !$0.isDiscarded },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try? context.fetch(descriptor).first
    }

    // MARK: 记录管理

    func delete(_ record: SessionRecord) {
        context.delete(record)
        save()
    }

    #if DEBUG
    /// 造 9 条跨日期演示记录（`-seedRecords` 钩子用）。
    /// 日期分布刻意留一个断档（3 天前），用于验证连续天数口径。
    func seedDemoRecords() {
        // 幂等：已有记录就不再造（模拟器数据库是持久的，重复 launch 会叠相同数据）
        let existing = (try? context.fetch(FetchDescriptor<SessionRecord>())) ?? []
        guard existing.isEmpty else {
            dbgLog("[seed] skipped: \(existing.count) records already exist")
            return
        }
        let cal = Calendar.current
        let now = Date()
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            cal.date(byAdding: .day, value: -dayOffset, to: cal.date(bySettingHour: hour, minute: minute, second: 0, of: now)!)!
        }
        let plan: [(Int, Int, Int, TimeInterval, String)] = [
            (0, 7, 30, 1500, "natural"),     // 今天 07:30 · 25 分
            (0, 12, 10, 480, "manual"),      // 今天 12:10 · 8 分（手动）
            (1, 21, 0, 1200, "natural"),     // 昨天 21:00 · 20 分
            (2, 7, 15, 2700, "natural"),     // 2 天前 · 45 分
            // 3 天前故意空 → 连续天数应断在这里
            (4, 19, 45, 600, "manual"),      // 4 天前 · 10 分
            (6, 8, 0, 1800, "natural"),      // 6 天前 · 30 分
            (9, 22, 20, 900, "natural"),     // 9 天前 · 15 分
            (12, 7, 0, 3600, "natural"),     // 12 天前 · 60 分
            (40, 7, 30, 1200, "natural"),    // 上个月 · 20 分（月份切换验证）
        ]
        for (index, (day, hour, minute, seconds, reason)) in plan.enumerated() {
            let started = at(day, hour, minute)
            let record = SessionRecord(
                startedAt: started,
                plannedDuration: seconds,
                interval: 300,
                chimeID: ChimeCatalog.default.id,
                endChimeID: ChimeCatalog.default.id,
                ambientID: day % 2 == 0 ? "rain" : nil
            )
            record.endedAt = started.addingTimeInterval(seconds)
            record.billableSeconds = seconds
            record.endReason = reason
            context.insert(record)
            // 演示体征样本：模拟手表静息采样节奏（心率 5-10 分钟一条、HRV 更稀疏），
            // 覆盖三种呈现态 —— series（4 点）/ series（2 点）/ single（1 点）/ hidden（无）
            seedVitals(for: record, plan: Self.vitalPlans[index])
        }
        save()
        dbgLog("[seed] demo records inserted")
    }

    /// 与 seedDemoRecords 的 plan 按下标对应的体征样本（offset 相对会话开始）。
    private static let vitalPlans: [[(VitalKind, TimeInterval, Double)]] = [
        // 0 · 今天 25 分：心率 4 条（series）+ HRV 2 条（series）
        [(.heartRate, 120, 64), (.heartRate, 540, 60), (.heartRate, 960, 59), (.heartRate, 1380, 58),
         (.hrvSDNN, 480, 42), (.hrvSDNN, 1200, 38)],
        // 1 · 今天 8 分：心率 2 条（series）
        [(.heartRate, 60, 68), (.heartRate, 240, 66)],
        // 2 · 昨天 20 分：心率 1 条（single）
        [(.heartRate, 600, 62)],
        // 3 起：无样本（hidden）
        [], [], [], [], [], [], [],
    ]

    private func seedVitals(for record: SessionRecord, plan: [(VitalKind, TimeInterval, Double)]) {
        for (index, item) in plan.enumerated() {
            let reading = VitalReading(
                kind: item.0,
                value: item.2,
                startDate: record.startedAt.addingTimeInterval(item.1),
                endDate: record.startedAt.addingTimeInterval(item.1),
                sourceID: "seed:\(record.id.uuidString):\(index)"
            )
            let row = VitalRecord(reading: reading)
            row.session = record
            context.insert(row)
        }
    }
    #endif

    // MARK: 恢复

    /// 最近一条未闭合的 open 记录（App 被杀留下的会话）。没有则 nil。
    func unfinishedRecord() -> SessionRecord? {
        openRecord()
    }

    private func openRecord() -> SessionRecord? {
        let descriptor = FetchDescriptor<SessionRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        // 记录量级小（百条内），不必上 #Predicate 的 optional 比较，Swift 侧过滤即可
        return try? context.fetch(descriptor).first(where: { $0.endedAt == nil })
    }

    /// 按 id 取记录（UI 层展示小结页用）。
    func record(id: UUID) -> SessionRecord? {
        let descriptor = FetchDescriptor<SessionRecord>()
        return try? context.fetch(descriptor).first(where: { $0.id == id })
    }
    private func save() {
        do {
            try context.save()
        } catch {
            // 绝不再用 try? 静默 —— 落库失败的代价是记录凭空丢失
            dbgLog("[journal] save FAILED: \(error)")
        }
    }
}
