import AppIntents
import Foundation

/// 灵动岛 / 锁屏上的「暂停 / 继续」按钮的意图。
///
/// 用 `LiveActivityIntent` 而不是普通 AppIntent：它允许在 **App 不启动、不进前台** 的情况下
/// 静默执行 —— 暂停无破坏性，不需要打断用户（用户 2026-10-20 决策：只有「结束」要走 App）。
@available(iOS 17.0, *)
public struct MeditationControlIntent: LiveActivityIntent {

    public static var title: LocalizedStringResource = "冥想控制"
    public static var description = IntentDescription("暂停或继续当前冥想。")

    @Parameter(title: "指令", description: "togglePause")
    public var command: String

    public init() {}

    public init(command: ControlBus.Command) {
        self.command = command.rawValue
    }

    public func perform() async throws -> some IntentResult {
        ControlBus.post(ControlBus.Command(rawValue: command) ?? .togglePause)
        return .result()
    }
}

/// 灵动岛 / 锁屏上的「结束」按钮的意图（用户 2026-10-20 决策）。
///
/// **不再静默结束**：普通 `AppIntent` + `openAppWhenRun = true` —— 点击先打开 App，
/// 由 App 内弹二次确认，确认后才执行结束逻辑（FR-2.3「结束需二次确认」）。
///
/// 指令经 **App Group 标志位**传递，而不是 `ControlBus` 的 Darwin 通知：
/// Darwin 通知是一次性无队列的，App 冷启动时发出的通知必然丢失；
/// 标志位持久化在共享容器里，App 激活后读取即可。
@available(iOS 17.0, *)
public struct MeditationEndIntent: AppIntent {

    public static var title: LocalizedStringResource = "结束冥想"
    public static var description = IntentDescription("打开 App，确认后结束本次冥想。")
    /// 关键：点击按钮时把 App 带到前台。
    public static var openAppWhenRun: Bool = true

    public init() {}

    public func perform() async throws -> some IntentResult {
        MeditationEndIntent.markPending()
        return .result()
    }

    // MARK: App Group 待处理标志

    public static let pendingKey = "pendingEndRequest"

    /// Widget 侧调用：标记「有一次结束请求等着处理」。
    public static func markPending() {
        UserDefaults(suiteName: ControlBus.appGroup)?.set(true, forKey: pendingKey)
    }

    /// App 激活时调用：取出并清除标志。返回 true 表示有待处理的结束请求。
    public static func consumePending() -> Bool {
        guard let defaults = UserDefaults(suiteName: ControlBus.appGroup) else { return false }
        let pending = defaults.bool(forKey: pendingKey)
        if pending { defaults.set(false, forKey: pendingKey) }
        return pending
    }

    /// 用户取消结束 / 确认后清除，避免残留标志在下次激活时误触发。
    public static func clearPending() {
        UserDefaults(suiteName: ControlBus.appGroup)?.set(false, forKey: pendingKey)
    }
}
