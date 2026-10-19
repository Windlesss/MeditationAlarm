import Foundation

// MARK: - 跨进程控制总线

/// 灵动岛 / 锁屏上的按钮跑在 **Widget Extension 进程**里，
/// 它们拿不到主 App 的对象，只能跨进程通信。
///
/// 用 Darwin 通知而不是写 App Group UserDefaults —— 后者需要主 App 轮询，
/// 通知是即时的。（后续若要传数据，会改用 App Group 容器。）
public enum ControlBus {

    public static let appGroup = "group.com.windlessd.MeditationAlarm"

    public enum Command: String, CaseIterable, Sendable {
        case togglePause
        case end

        var notificationName: CFNotificationName {
            CFNotificationName(rawValue: "\(ControlBus.appGroup).\(rawValue)" as CFString)
        }
    }

    /// Widget 侧调用。
    public static func post(_ command: Command) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            command.notificationName,
            nil, nil, true
        )
    }
}

// MARK: - 主 App 侧监听

public final class DarwinListener: @unchecked Sendable {

    private let handler: (ControlBus.Command) -> Void

    public init(handler: @escaping (ControlBus.Command) -> Void) {
        self.handler = handler
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        for command in ControlBus.Command.allCases {
            // 注意第 5 个参数是 `object`（必须给 nil），第 6 个才是投递策略
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                pointer,
                Self.receive,
                command.notificationName.rawValue,
                nil,
                .deliverImmediately
            )
        }
    }

    private static let receive: CFNotificationCallback = { _, pointer, name, _, _ in
        guard let pointer, let name else { return }
        let raw = name.rawValue as String
        let listener = Unmanaged<DarwinListener>.fromOpaque(pointer).takeUnretainedValue()
        guard let command = ControlBus.Command.allCases.first(where: {
            raw == $0.notificationName.rawValue as String
        }) else { return }
        DispatchQueue.main.async { listener.handler(command) }
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}
