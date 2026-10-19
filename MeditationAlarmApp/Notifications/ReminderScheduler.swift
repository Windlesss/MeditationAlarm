import Foundation
import UserNotifications

/// 本地通知兜底。方案 C 的另一半，**前后台互斥**：
/// **前台声音由音频会话负责，退后台后全部交给本地通知** ——
/// 用户上滑杀掉 App 后音频立即失效，只有已排程的通知还能按时响。
///
/// 互斥策略（替代早期的「滚动排下一发」）：
/// - 退后台时**一次排完全部剩余间隔**（iOS 待投递上限 64 枚，超出截断并记日志）；
/// - App 在前台时一条都不排 —— 前台提示由 App 内 Timer 发声，两个路径
///   永远只有一个在干活，不会出现「同一点边界响两声」；
/// - 回前台 / 暂停 / 结束立即全量撤下。
///
/// 通知声音用**用户选的提示音的 caf 副本**（`Resources/Audio/chimes-caf/`）：
/// 通知只支持 aiff/wav/caf，不支持 m4a，且时长须 < 30 秒（我们的素材 2–3 秒）。
/// 已知平台限制：通知声音受系统静音开关控制；App 存活时通知音不触发背景音 ducking。
enum ReminderScheduler {

    private static let endID = "meditation.end"
    private static let intervalIDPrefix = "meditation.interval."

    /// iOS 限制待投递本地通知总数为 64 条。
    private static let maxPending = 64

    /// 已排程的间隔通知 ID。disarm 要按 ID 全量撤下，系统不支持按前缀删除。
    private static var armedIntervalIDs: [String] = []

    // MARK: 权限

    /// 首次开始会话时调用。只在「未决定」时申请，不重复打扰；
    /// 已拒绝也不做设置引导（v1 从简，记日志）。
    static func ensureAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                dbgLog("[notify] authorization granted=\(granted) error=\(String(describing: error))")
            }
        }
    }

    // MARK: 排程

    /// 退后台时调用：一次排完全部剩余间隔 + 结束。
    /// - Parameters:
    ///   - intervals: 全部剩余间隔提示时刻（调用方通常已按 limit 截断，这里再兜一层 64 上限）
    ///   - end: 预计结束时刻；永久模式传 nil
    ///   - soundName: 通知声音文件名（bundle 根目录下的 .caf），如 "bowl-deep-01.caf"
    static func armAll(intervals: [Date], end: Date?, soundName: String) {
        let center = UNUserNotificationCenter.current()
        disarm()

        let budget = maxPending - (end == nil ? 0 : 1)
        let capped = intervals.prefix(max(0, budget))
        if capped.count < intervals.count {
            dbgLog("[notify] \(intervals.count - capped.count) of \(intervals.count) intervals dropped (64 limit)")
        }

        var ids: [String] = []
        for (index, date) in capped.enumerated() {
            let id = "\(intervalIDPrefix)\(index)"
            center.add(makeRequest(
                id: id,
                title: "冥想提示",
                body: "回到呼吸。",
                soundName: soundName,
                at: date
            ))
            ids.append(id)
        }
        armedIntervalIDs = ids

        if let end {
            center.add(makeRequest(
                id: endID,
                title: "冥想完成",
                body: "本次冥想结束。",
                soundName: soundName,
                at: end
            ))
        }
        dbgLog("[notify] armed \(ids.count) intervals + \(end != nil ? 1 : 0) end, sound=\(soundName)")
    }

    /// 回前台 / 暂停 / 会话结束时调用：全量撤下。
    static func disarm() {
        var ids = armedIntervalIDs
        ids.append(endID)
        armedIntervalIDs = []
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: 私有

    private static func makeRequest(
        id: String,
        title: String,
        body: String,
        soundName: String,
        at date: Date
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
        // 冥想提示应当穿透专注模式 —— 用户开冥想正是为了不被别的事打扰，
        // 但报时本身必须被听到。timeSensitive 不需要额外 entitlement。
        content.interruptionLevel = .timeSensitive
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}
