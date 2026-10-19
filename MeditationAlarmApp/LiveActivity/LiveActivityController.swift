import ActivityKit
import Foundation

/// Live Activity 生命周期管理。**这一层缺失就是「App 没有上实时活动」的原因** ——
/// Widget 侧画好了视图，但 App 侧从不调用 `request`，系统自然无从显示。
///
/// 关键设计：
/// - **只传绝对时刻，不传剩余秒数**。`Text(endDate, style: .timer)` 由系统逐秒刷新，
///   零更新预算消耗，App 被杀后数字照走。
/// - **`sync()` 只在状态变化时调用**（start / pause / resume）。运行中不更新 ——
///   每秒 `update` 会迅速耗尽 Live Activity 的更新预算。
/// - **self-healing**：App 回前台发现「计时在跑但没有活动」就重建。
///   系统 8 小时上限、用户误杀 App 都会让活动消失，两种情况一并修掉。
///
/// 注意：`Activity.request` 是同步 `throws`（不是 async），所以上岛没有异步延迟；
/// `update` / `end` 才是 async。
@MainActor
final class LiveActivityController {

    static let shared = LiveActivityController()

    private var activity: Activity<MeditationActivityAttributes>?

    /// 本次会话摘要，重建活动时要用（`Activity.activities` 里拿不到 attributes）。
    private var summary: String = ""

    var isActive: Bool { activity != nil }

    private init() {}

    // MARK: - 生命周期

    func start(clock: SessionClock, summary: String) {
        self.summary = summary
        // 清掉可能残留的旧活动，避免同时出现两个岛
        if let old = activity {
            activity = nil
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        request(clock: clock)
    }

    /// 状态变化时同步内容。**不要在心跳里每秒调** —— 预算会爆。
    func sync(clock: SessionClock) {
        guard let activity else { return }
        let state = MeditationActivityAttributes.ContentState.snapshot(from: clock)
        let content = ActivityContent(state: state, staleDate: staleDate(for: clock))
        Task { await activity.update(content) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// App 回前台自检。计时还在跑但活动不在了 → 重建。
    /// 因为真相源是绝对时间戳，重建不影响计时精度。
    func repairIfNeeded(clock: SessionClock, summary: String) {
        self.summary = summary
        guard activity == nil else { return }
        // 有正在运行的段，或有已完成段（暂停中），都值得重建
        guard clock.segmentStart != nil || !clock.finishedSegments.isEmpty else { return }
        request(clock: clock)
    }

    // MARK: - 私有

    private func request(clock: SessionClock) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            dbgLog("[island] request skipped: activities not enabled")
            return
        }
        let attributes = MeditationActivityAttributes(summary: summary)
        let state = MeditationActivityAttributes.ContentState.snapshot(from: clock)
        let content = ActivityContent(state: state, staleDate: nil)
        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            dbgLog("[island] requested OK, summary = \(summary)")
        } catch {
            activity = nil
            dbgLog("[island] request FAILED: \(error)")
        }
    }

    /// 暂停态给一个半小时的陈旧线 —— 用户暂停后太久没回来，让系统给个视觉提示。
    private func staleDate(for clock: SessionClock) -> Date? {
        clock.segmentStart == nil ? Date().addingTimeInterval(1800) : nil
    }
}
