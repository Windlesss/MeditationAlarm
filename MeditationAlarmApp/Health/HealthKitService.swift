import Foundation
import HealthKit

/// HealthKit 门面（第三阶段 v3a，用户 2026-10-20 决策）。
///
/// **授权策略——无开关、无配置、默认后台运行**：
/// - 首次会话开始时请求一次（本地 UserDefaults 标记去重，之后永不重复）；
/// - 按 `WatchPresence.isPaired` 分流：有手表 → 请求读（心率 / HRV）+ 写（正念）；
///   无手表（含 iPad）→ 只请求写（正念）；
/// - 被拒则静默到底：不二次弹窗、不引导去设置。HealthKit 的读授权状态不可查，
///   本地标记 + FR-10.5「无数据整块隐藏」天然兜底。
///
/// **正念写入承接记录逻辑**（用户决策）：写记录才写、不写记录不写。
/// 由 `SessionJournal` 在静默落库 / commitPending 时调用；作废记录不调用。
@MainActor
final class HealthKitService {

    static let shared = HealthKitService()

    private let store = HKHealthStore()

    /// 「已请求过授权」的本地标记。HealthKit 不会告诉我们问没问过，
    /// 自己去重 —— 重复调用 requestAuthorization 对已决定的类型是无操作，
    // 但会白跑一趟 completion。
    private let requestedKey = "health.authorization.requested"

    private init() {}

    // MARK: 可用性

    /// HealthKit 是否可用（iPad 上受限，模拟器可用）。
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var mindfulType: HKCategoryType { HKCategoryType(.mindfulSession) }

    // MARK: 授权

    /// 首次会话开始时调用。内部自行去重，重复调用无副作用。
    func requestAuthorizationIfNeeded() {
        guard isAvailable else {
            dbgLog("[health] unavailable on this device, skip authorization")
            return
        }
        guard !UserDefaults.standard.bool(forKey: requestedKey) else { return }
        UserDefaults.standard.set(true, forKey: requestedKey)

        let write: Set<HKSampleType> = [mindfulType]
        var read = Set<HKObjectType>()
        // 有手表才要读权限：授权页越短通过率越高；没手表要了也永远不会有数据
        if WatchPresence.shared.isPaired {
            if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) { read.insert(hr) }
            if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { read.insert(hrv) }
        }

        store.requestAuthorization(toShare: write, read: read) { _, error in
            // 成功 / 失败走同一条静默路径，这里只留诊断日志
            if let error {
                dbgLog("[health] authorization error: \(error)")
            } else {
                dbgLog("[health] authorization completed, readTypes = \(read.count)")
            }
        }
    }

    // MARK: 正念分钟数写入

    /// 写入正念分钟数。**承接记录逻辑**：只有成立了的记录才会被调用到这里。
    ///
    /// - Parameter segments: 实际运行区间（暂停已剔除，由 `SessionClock.ending` 产出）
    /// - Returns: `true` = 无需再重试（写成功 / 无内容可写 / 设备无 HealthKit）；
    ///   `false` = 未授权或写失败，交给前台重试（`SessionJournal.retryMindfulWrites`）。
    func writeMindfulSession(segments: [TimedSegment]) async -> Bool {
        guard isAvailable else { return true }

        let writable = SessionClock.writableSegments(segments)
        guard !writable.isEmpty else { return true }   // 没有达到阈值的区间 = 无事可做

        // 写授权状态**可以**查（读的不行）—— 未授权时不做无谓的 save
        guard store.authorizationStatus(for: mindfulType) == .sharingAuthorized else {
            dbgLog("[health] mindful write skipped: not authorized")
            return false
        }

        let samples = writable.map {
            HKCategorySample(
                type: mindfulType,
                value: HKCategoryValue.notApplicable.rawValue,   // 必须为 0，填别的会被拒
                start: $0.start,
                end: $0.end
            )
        }
        do {
            try await store.save(samples)
            dbgLog("[health] mindful saved \(samples.count) segment(s)")
            return true
        } catch {
            dbgLog("[health] mindful save FAILED: \(error)")
            return false
        }
    }
}
