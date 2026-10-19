import ActivityKit
import Foundation

/// Live Activity 的静态部分：创建时一次写入，之后不变。
///
/// **重要**：Live Activity 只负责「显示」，它跑在独立的 Widget Extension 进程里，
/// 不能播放声音、不能执行计时。真正的计时真相源在 App 的 `SessionClock`。
public struct MeditationActivityAttributes: ActivityAttributes {

    public typealias MeditationStatus = ContentState

    /// 动态部分：每次 `update()` 传进来。
    ///
    /// 关键设计：**倒计时不传「剩余秒数」，而传「结束的绝对时刻」。**
    /// 这样才能用 `Text(date, style: .timer)` —— 倒数由**系统**负责逐秒刷新，
    /// 不消耗 Live Activity 的更新预算，App 被杀后数字也照走。
    ///
    /// 剩下两份口头数据（`startedAt` / `accumulated`）用于**暂停态**回算已冥想时长。
    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: Phase
        /// 当前运行段起点（暂停态下等于暂停发生前那段的起点）。
        public var startedAt: Date
        /// 已完成段的累计秒数。
        public var accumulated: TimeInterval
        public var plannedDuration: TimeInterval?
        public var interval: TimeInterval?

        /// 倒计时的目标时刻。`nil` = 永久运行（没有倒数终点）。
        public var targetEnd: Date?
        /// 更新发生那一瞬的已冥想秒数。暂停态与永久模式用它做静态显示。
        public var snapshotElapsed: TimeInterval

        public init(
            phase: Phase,
            startedAt: Date,
            accumulated: TimeInterval,
            plannedDuration: TimeInterval?,
            interval: TimeInterval?,
            targetEnd: Date?,
            snapshotElapsed: TimeInterval
        ) {
            self.phase = phase
            self.startedAt = startedAt
            self.accumulated = accumulated
            self.plannedDuration = plannedDuration
            self.interval = interval
            self.targetEnd = targetEnd
            self.snapshotElapsed = snapshotElapsed
        }

        /// 暂停态 / 永久模式下的静态文本。
        public var staticRemainingText: String? {
            guard let plannedDuration else { return nil }
            return TimeFormatter.string(max(0, plannedDuration - snapshotElapsed))
        }
    }

    public enum Phase: String, Codable, Sendable {
        case running
        case paused
        case ended
    }

    /// 配置摘要，静止区域展示（如「50 分钟 · 间隔 5 分钟」）。
    public var summary: String

    public init(summary: String) {
        self.summary = summary
    }
}

// MARK: - 唯一的转换入口

extension MeditationActivityAttributes.ContentState {

    /// 从 App 的 SessionClock 生成快照。两侧口径靠这个方法保持一致。
    public static func snapshot(from clock: SessionClock, at now: Date = Date()) -> Self {
        let isRunning = clock.segmentStart != nil
        let elapsed = clock.elapsed(at: now)
        return Self(
            phase: isRunning ? .running : .paused,
            startedAt: clock.segmentStart ?? clock.finishedSegments.last?.end ?? now,
            accumulated: clock.accumulated,
            plannedDuration: clock.plannedDuration,
            interval: clock.interval,
            // 运行且非永久时才给终点；暂停时 targetEnd 置 nil，改显示静态文本
            targetEnd: (isRunning && clock.plannedDuration != nil) ? clock.endDate(from: now) : nil,
            snapshotElapsed: elapsed
        )
    }
}
