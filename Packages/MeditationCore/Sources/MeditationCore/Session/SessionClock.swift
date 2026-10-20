import Foundation

// MARK: - TimedSegment

/// 一段「真正在冥想」的时间区间。
/// 暂停的时长不在任何区间内 —— 这是 HealthKit 正念分钟数不虚报的关键。
public struct TimedSegment: Equatable, Sendable, Hashable, Codable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

// MARK: - SessionClock

/// 计时真相源。
///
/// **绝对时间戳，绝不累加。** iOS 后台会把 Timer 降频甚至暂停，任何 "每帧 +1" 的写法
/// 在后台 / 息屏场景下必然漂移。这里只持久化几个绝对时间点，UI 每次拿 `now` 反算。
///
/// 附带好处：冷启动、App 被杀、跨时区都天然正确。
public struct SessionClock: Equatable, Sendable {

    // MARK: 持久化字段

    /// 当前运行段的起点。`nil` 表示已暂停 / 已结束。
    public let segmentStart: Date?
    /// 之前所有已完成段的累计秒数。
    public let accumulated: TimeInterval
    /// 已完成的历史段（供 HealthKit 分段写入）。
    public let finishedSegments: [TimedSegment]
    /// 计划总时长。`nil` = 永久运行。
    public let plannedDuration: TimeInterval?
    /// 间隔提示周期。`nil` = 无间隔提示。
    public let interval: TimeInterval?

    public init(
        segmentStart: Date?,
        accumulated: TimeInterval,
        finishedSegments: [TimedSegment],
        plannedDuration: TimeInterval?,
        interval: TimeInterval?
    ) {
        self.segmentStart = segmentStart
        self.accumulated = accumulated
        self.finishedSegments = finishedSegments
        self.plannedDuration = plannedDuration
        self.interval = interval
    }

    /// 开始一次新会话（立即进入运行态）。
    public static func start(
        at now: Date = Date(),
        plannedDuration: TimeInterval?,
        interval: TimeInterval?
    ) -> SessionClock {
        SessionClock(
            segmentStart: now,
            accumulated: 0,
            finishedSegments: [],
            plannedDuration: plannedDuration,
            interval: interval
        )
    }

    // MARK: 读取

    public var isRunning: Bool { segmentStart != nil }

    /// 已进行秒数。有计划时长时**截断**到计划值 —— 这样到点显示的一定是 30:00 而不是 30:00.4。
    public func elapsed(at now: Date) -> TimeInterval {
        let running = segmentStart.map { now.timeIntervalSince($0) } ?? 0
        let raw = accumulated + running
        // 时钟回拨或负值时兜底到 0
        guard let plannedDuration else { return max(0, raw) }
        return min(max(0, raw), plannedDuration)
    }

    /// 剩余秒数。`nil` 表示永久运行（没有剩余的概念）。
    public func remaining(at now: Date) -> TimeInterval? {
        guard let plannedDuration else { return nil }
        return max(0, plannedDuration - elapsed(at: now))
    }

    /// 进度 0...1。永久运行返回 `nil`。
    public func progress(at now: Date) -> Double? {
        guard let plannedDuration, plannedDuration > 0 else { return nil }
        return min(1, max(0, elapsed(at: now) / plannedDuration))
    }

    public func isFinished(at now: Date) -> Bool {
        guard let plannedDuration else { return false }
        return elapsed(at: now) >= plannedDuration
    }

    /// 预计结束的绝对时间点。Live Activity 用 `Text(date, style: .timer)` 直接消费它，
    /// 由系统自己倒数 —— 不消耗 Live Activity 更新预算，App 被杀数字也继续走。
    public func endDate(from now: Date = Date()) -> Date? {
        guard let plannedDuration else { return nil }
        return now.addingTimeInterval(max(0, plannedDuration - elapsed(at: now)))
    }

    // MARK: 状态迁移

    public func pausing(at now: Date) -> SessionClock {
        guard let start = segmentStart else { return self }
        let end = min(now, clampedEnd(from: start))
        return SessionClock(
            segmentStart: nil,
            accumulated: accumulated + end.timeIntervalSince(start),
            finishedSegments: finishedSegments + [TimedSegment(start: start, end: end)],
            plannedDuration: plannedDuration,
            interval: interval
        )
    }

    public func resuming(at now: Date) -> SessionClock {
        guard segmentStart == nil else { return self }
        guard let plannedDuration, accumulated >= plannedDuration else {
            return SessionClock(
                segmentStart: now,
                accumulated: accumulated,
                finishedSegments: finishedSegments,
                plannedDuration: plannedDuration,
                interval: interval
            )
        }
        return self
    }

    /// 结束会话。返回新的 clock 与完整的运行区间数组。
    public func ending(at now: Date) -> (clock: SessionClock, segments: [TimedSegment]) {
        let paused = pausing(at: now)
        return (
            SessionClock(
                segmentStart: nil,
                accumulated: paused.accumulated,
                finishedSegments: paused.finishedSegments,
                plannedDuration: plannedDuration,
                interval: interval
            ),
            paused.finishedSegments
        )
    }

    // MARK: HealthKit 分段

    /// 转换为可写入 HealthKit 的区间，丢弃短于阈值的（试试 10 秒就放弃不该记账）。
    public static func writableSegments(
        _ segments: [TimedSegment],
        minimumDuration: TimeInterval = DurationPolicy.minimumSynced
    ) -> [TimedSegment] {
        segments.filter { $0.duration >= minimumDuration }
    }

    /// 实际写入 HealthKit 的总时长（暂停不计）。
    public static func billableDuration(
        _ segments: [TimedSegment],
        minimumDuration: TimeInterval = DurationPolicy.minimumSynced
    ) -> TimeInterval {
        writableSegments(segments, minimumDuration: minimumDuration).reduce(0) { $0 + $1.duration }
    }

    // MARK: 私有

    /// 当前运行段允许达到的最晚时间（受计划总时长约束）。
    private func clampedEnd(from start: Date) -> Date {
        guard let plannedDuration else { return .distantFuture }
        return start.addingTimeInterval(max(0, plannedDuration - accumulated))
    }
}
