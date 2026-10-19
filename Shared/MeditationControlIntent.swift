import AppIntents
import Foundation

/// 灵动岛 / 锁屏按钮的意图。
///
/// 用 `LiveActivityIntent` 而不是普通 AppIntent：它允许在 **App 不启动、不进前台** 的情况下
/// 静默执行 —— 这正是灵动岛按钮的场景。（普通 Intent 会尝试打开 App。）
@available(iOS 17.0, *)
public struct MeditationControlIntent: LiveActivityIntent {

    public static var title: LocalizedStringResource = "冥想控制"
    public static var description = IntentDescription("暂停、继续或结束当前冥想。")

    @Parameter(title: "指令", description: "togglePause 或 end")
    public var command: String

    public init() {}

    public init(command: ControlBus.Command) {
        self.command = command.rawValue
    }

    public func perform() async throws -> some IntentResult {
        ControlBus.post(ControlBus.Command(rawValue: command) ?? .end)
        return .result()
    }
}
