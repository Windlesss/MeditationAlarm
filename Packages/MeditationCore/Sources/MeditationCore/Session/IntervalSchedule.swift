import Foundation

// MARK: - 可选间隔档位

/// FR-1.3：间隔提示的可选档位。`nil` = 无。
public enum IntervalOption: Sendable, CaseIterable, Identifiable, Hashable {
    case none
    case fixed(TimeInterval)

    public static var allCases: [IntervalOption] {
        [.none,.fixed(15), .fixed(60), .fixed(180), .fixed(300), .fixed(600), .fixed(1800)]
    }

    public var id: TimeInterval { seconds ?? -1 }

    public var seconds: TimeInterval? {
        switch self {
        case .none: return nil
        case .fixed(let s): return s
        }
    }

    public var label: String {
        switch self {
        case .none:
            return "无"
        case .fixed(let s):
            return s < 60 ? "\(Int(s)) 秒" : "\(Int(s / 60)) 分钟"
        }
    }
}

// MARK: - 时长联动规则

public struct ResolvedDuration: Equatable, Sendable {
    public let plannedDuration: TimeInterval?   // nil = 永久
    public let wasAdjusted: Bool                // 是否触发了自动扩容
    public let adjustedFrom: TimeInterval?      // 用户原本输入的值
}

public enum DurationPolicy: Sendable {

    /// 写入 HealthKit 的最短冥想时长（秒）。低于此值不计为正念。
    public static let minimumSynced: TimeInterval = 60

    /// 输入允许的范围（分钟）。
    public static let minuteRange: ClosedRange<Int> = 1...600

    /// FR-1.4 联动规则：
    /// **总时长 < 间隔 → 自动扩大为间隔 × 5**；否则保留用户输入。
    ///
    /// 注意 `[间隔, 间隔×5)` 之间的值**不强制拉到 5 倍**（Q5 的决定：尊重用户输入）。
    /// 例：间隔 10 分钟 + 输入 15 分钟 → 保持 15 分钟。
    ///     间隔 10 分钟 + 输入 3 分钟 → 扩容为 50 分钟。
    public static func resolve(
        plannedDuration: TimeInterval?,
        interval: TimeInterval?
    ) -> ResolvedDuration {
        guard let interval, interval > 0, let plannedDuration else {
            return ResolvedDuration(plannedDuration: plannedDuration, wasAdjusted: false, adjustedFrom: nil)
        }
        if plannedDuration < interval {
            return ResolvedDuration(
                plannedDuration: interval * 5,
                wasAdjusted: true,
                adjustedFrom: plannedDuration
            )
        }
        return ResolvedDuration(plannedDuration: plannedDuration, wasAdjusted: false, adjustedFrom: nil)
    }
}

// MARK: - 间隔提示调度

/// 间隔打铃的绝对时间调度。
///
/// **不预先排程，每次用 `now` 反算下一次的时刻。** 这是自纠正的：
/// 暂停后继续、App 被杀重启、系统时钟微调，都不需要重建排程，下一发自动对齐到正确时刻。
public struct Reminder: Equatable, Sendable {
    /// 第几次（从 1 开始）。用于防止同一发重复播放。
    public let index: Int
    public let date: Date
}

public enum IntervalSchedule: Sendable {

    /// 下一次该响的时刻。已经在结束点之后则返回 `nil`（结束音会覆盖，不需要再补一记间隔音）。
    ///
    /// - Returns: `nil` 表示「本次不会再有间隔提示」
    public static func nextReminder(
        clock: SessionClock,
        from now: Date = Date()
    ) -> Reminder? {
        guard let interval = clock.interval, interval > 0 else { return nil }
        let e = clock.elapsed(at: now)
        let index = Int(floor(e / interval)) + 1
        let target = TimeInterval(index) * interval

        if let planned = clock.plannedDuration, target >= planned { return nil }

        return Reminder(index: index, date: now.addingTimeInterval(target - e))
    }

    /// 给定计划，一次性算出所有间隔提示时刻（用于排程本地通知兜底）。
    /// 时长超过 8 小时的通知预算时注意截断。
    public static func allReminders(
        plannedDuration: TimeInterval?,
        interval: TimeInterval?,
        sessionStart: Date
    ) -> [Reminder] {
        guard let interval, interval > 0 else { return [] }
        guard let plannedDuration else { return [] }   // 永久模式不排程（排不完）
        var result: [Reminder] = []
        var index = 1
        while true {
            let t = TimeInterval(index) * interval
            if t >= plannedDuration { break }
            result.append(Reminder(index: index, date: sessionStart.addingTimeInterval(t)))
            index += 1
        }
        return result
    }

    /// 从**当前进度**反算全部剩余提示时刻 —— 退后台时一次排完用。
    ///
    /// 与 `nextReminder` 共用同一套 elapsed 反算逻辑，因此暂停/重启/时钟微调后
    /// 排程依然对齐；区别只是把后面每一发都算出来，而不是只给下一发。
    /// App 挂起后没人能滚动重排，所以后台必须一次性排完（受 iOS 64 枚上限约束，
    /// 由调用方截断；永久模式靠 `limit` 兜底，回前台会撤下重排）。
    public static func remainingReminders(
        clock: SessionClock,
        from now: Date = Date(),
        limit: Int = 60
    ) -> [Reminder] {
        guard let interval = clock.interval, interval > 0 else { return [] }
        let e = clock.elapsed(at: now)
        var result: [Reminder] = []
        var index = Int(floor(e / interval)) + 1
        while result.count < limit {
            let target = TimeInterval(index) * interval
            if let planned = clock.plannedDuration, target >= planned { break }
            result.append(Reminder(index: index, date: now.addingTimeInterval(target - e)))
            index += 1
        }
        return result
    }
}
