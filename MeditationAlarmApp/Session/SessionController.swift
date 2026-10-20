import Foundation
import Observation
import UIKit

/// 一次冥想的运行时状态机 + 计时中枢。
///
/// 设计要点：
/// - **计时真相源是 `SessionClock`（绝对时间戳）**。这里的 Timer 只负责「让 UI 重画」，
///   不参与任何累加。后台 Timer 会被降频甚至暂停，拿它计时必然漂移。
/// - **发声走 GCD 调度链，不走主 RunLoop**（2026-10-19 方案 B，用户真机决策）：
///   主 RunLoop 的 Timer 在锁屏态会被系统节流（真机实测：前台正常、后台未锁
///   基本正常、后台锁定完全不触发），所以间隔音与结束音的触发全部改挂在私有
///   队列的 `DispatchSourceTimer` 上 —— App 活着时它不受 RunLoop 节流影响。
///   「下一次事件」= min(下一间隔提示, 结束时刻)，一次只排一个，到点自愈重排；
///   前台 / 后台 / 锁屏三种状态走同一条链，不存在前后台双路径，也不会双响。
/// - **App 必须活着，调度链才活着**。背景音循环播放时，音频会话天然守住 App；
///   选「无背景音」时，退后台会起一段循环数字静音（`beginSilentKeepAlive`）
///   达到同样效果 —— 否则系统会在几十秒内挂起 App，调度链随之停摆。
/// - **本地通知已停用**（用户 2026-10-19 决策）：`ReminderScheduler` 代码与
///   caf 素材保留但不再排程、不再申请权限，只在状态切换时 disarm 清理残留。
/// - **屏幕常亮 ⟺ 正在运行**（用户 2026-10-19 决策）：`phase == .running` 时
///   禁用系统空闲计时；暂停 / 结束 / 退后台一律恢复自动锁屏。无开关。
/// - Live Activity 负责「看得见」。
@MainActor
@Observable
final class SessionController {

    enum Phase: Equatable, Sendable {
        case idle
        case running
        case paused
        case ended
    }

    /// 结束的触发方式，决定收尾音形态（用户 2026-10-18/19 决策）。
    enum EndReason: Sendable {
        /// 用户主动点「结束」（App 内按钮或灵动岛）—— 单声收场。
        case manual
        /// 自然到点（前台 / 后台 / 锁屏一视同仁）—— 三声渐强。
        case natural
    }

    // MARK: 对外只读状态

    private(set) var phase: Phase = .idle
    private(set) var clock = SessionClock(
        segmentStart: nil, accumulated: 0, finishedSegments: [],
        plannedDuration: nil, interval: nil
    )
    /// UI 心跳。**只用于触发重绘**，不用于计量。
    private(set) var tick: Date = .now

    /// 本次运行的配置（结算与小结页用）。
    private(set) var chimeID: String = ChimeCatalog.default.id
    private(set) var endChimeID: String = ChimeCatalog.default.id
    private(set) var ambientID: String?
    private(set) var chimeVolume: Double = 0.8
    private(set) var ambientVolume: Double = 0.5
    private(set) var wasAutoAdjusted = false

    /// 灵动岛 / 锁屏上展示的配置摘要，如「50 分钟 · 间隔 5 分钟」。
    var sessionSummary: String {
        var parts: [String] = []
        if let planned = clock.plannedDuration {
            parts.append(TimeFormatter.minutesString(planned))
        } else {
            parts.append("永久")
        }
        if let interval = clock.interval, interval > 0 {
            // 小于 1 分钟的间隔（自测或未来的细粒度选项）按秒显示，
            // 否则会算出「间隔 0 分钟」
            if interval >= 60 {
                parts.append("间隔 \(Int(interval / 60)) 分钟")
            } else {
                parts.append("间隔 \(Int(interval)) 秒")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 外部注入

    /// App 是否在后台。由 scenePhase 驱动；方案 B 下只用于决定是否起静音守护
    /// （发声本身不再分前后台，见 `enterBackground`）。
    var isInBackground = false

    // MARK: 私有

    // deinit 是非隔离上下文，而本类是 @MainActor，直接访问 Timer 会编译不过。
    // `nonisolated` 用不了 —— @Observable 宏把属性变成 ObservationTracked 可变存储，
    // 明确拒绝 nonisolated。`nonisolated(unsafe)` 是唯一可行解，
    // 编译器会对宏展开的中间属性报一条「has no effect」警告，无害，可忽略。
    // 这两个计时器只在主线程被触碰。
    private nonisolated(unsafe) var uiTimer: Timer?
    private nonisolated(unsafe) var chimeSource: DispatchSourceTimer?
    private var lastFiredIndex = 0
    private var lastIslandSync: Date = .distantPast

    /// 调度链的私有队列。脱离主 RunLoop 是方案 B 的核心：
    /// 主 RunLoop 的 Timer 在锁屏态被系统节流，GCD 定时器不受影响。
    private let chimeQueue = DispatchQueue(
        label: "com.windlessd.MeditationAlarm.chime",
        qos: .userInitiated
    )

    deinit {
        uiTimer?.invalidate()
        chimeSource?.cancel()
    }

    // MARK: 派生值

    var isActive: Bool { phase == .running || phase == .paused }

    var elapsed: TimeInterval { clock.elapsed(at: tick) }
    var remaining: TimeInterval? { clock.remaining(at: tick) }
    var progress: Double? { clock.progress(at: tick) }
    var elapsedText: String { TimeFormatter.string(elapsed) }

    var remainingText: String {
        guard let remaining else { return TimeFormatter.string(elapsed) }
        return TimeFormatter.string(remaining)
    }

    /// 永久模式（无计划时长）下没有「剩余」的概念，显示已冥想时长。
    var isPerpetual: Bool { clock.plannedDuration == nil }

    // MARK: 屏幕常亮

    /// 常亮规则（用户 2026-10-19 决策）：**只有「正在运行」才禁用系统空闲计时**；
    /// 暂停 / 结束 / 退后台 / 其它页面一律恢复自动锁屏。无开关、无配置。
    ///
    /// 不变量：任何时刻 `isIdleTimerDisabled == (phase == .running)` ——
    /// 每个状态切换点都调一次，异常路径（崩溃随进程消亡）也不会残留。
    /// 注意它只在前台有效，且拦不住侧边按钮手动锁屏（没有公开 API 能拦）。
    private func syncIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = (phase == .running)
    }

    // MARK: 生命周期

    struct Configuration {
        var plannedDuration: TimeInterval?   // nil = 永久
        var interval: TimeInterval?
        var chimeID: String
        var endChimeID: String
        var ambientID: String?
        var chimeVolume: Double = 0.8
        var ambientVolume: Double = 0.5
        var wasAutoAdjusted: Bool
    }

    func start(_ configuration: Configuration) {
        stopTimers()
        lastFiredIndex = 0
        lastIslandSync = .distantPast

        chimeID = configuration.chimeID
        endChimeID = configuration.endChimeID
        ambientID = configuration.ambientID
        chimeVolume = configuration.chimeVolume
        ambientVolume = configuration.ambientVolume
        wasAutoAdjusted = configuration.wasAutoAdjusted

        clock = .start(
            at: Date(),
            plannedDuration: configuration.plannedDuration,
            interval: configuration.interval
        )
        tick = Date()
        phase = .running

        // 顺序有讲究：先起音频（拿到后台播放能力），再上岛。
        AudioEngine.shared.beginSession(
            ambient: AmbientCatalog.resolve(configuration.ambientID),
            chimeVolume: configuration.chimeVolume,
            ambientVolume: configuration.ambientVolume
        )
        LiveActivityController.shared.start(clock: clock, summary: sessionSummary)

        // 落 open 记录：结束前它一直带着时钟快照（暂停 / 继续时更新），
        // App 被杀后重启靠它恢复会话（restoreIfNeeded）。
        SessionJournal.shared.begin(configuration: configuration)

        // 通知已停用（2026-10-19 决策）：不申请权限、不排程，
        // 这里只清掉上一版可能残留的排程。
        ReminderScheduler.disarm()

        syncIdleTimer()
        startUITimer()
        scheduleNextChime()
    }

    func pause() {
        guard phase == .running else { return }
        clock = clock.pausing(at: Date())
        chimeSource?.cancel()
        chimeSource = nil
        phase = .paused
        SessionJournal.shared.checkpoint(clock)
        syncIdleTimer()          // 暂停 → 恢复自动锁屏倒计时
        LiveActivityController.shared.sync(clock: clock)
    }

    func resume() {
        guard phase == .paused else { return }
        clock = clock.resuming(at: Date())
        tick = Date()
        phase = .running
        SessionJournal.shared.checkpoint(clock)
        syncIdleTimer()          // 继续 → 重新常亮
        LiveActivityController.shared.sync(clock: clock)
        scheduleNextChime()
    }

    /// 结束会话。返回运行区间数组（暂停时长已剔除），交给 HealthKit 记账。
    ///
    /// 收尾音按触发方式分流（用户 2026-10-18/19 决策）：
    /// - 自然到点（**前台 / 后台 / 锁屏一视同仁**）→ 三声渐强；
    /// - 手动结束 → 单声，中途收场不需要仪式感。
    /// 后台自然结束以前只能靠通知发单声（平台能力边界）；方案 B 之后调度链在
    /// 后台照样能播完整渐强 —— 这是相对通知兜底的根本优势。
    @discardableResult
    func end(reason: EndReason) -> [TimedSegment] {
        guard isActive else { return [] }
        stopTimers()
        let (ended, segments) = clock.ending(at: Date())
        clock = ended
        phase = .ended
        syncIdleTimer()
        LiveActivityController.shared.end()
        ReminderScheduler.disarm()
        // 结束音由引擎自行收尾：setActive(false) 会把尾声掐掉，
        // 所以引擎会延后关闭音频会话（并淡出背景音）。
        let style: AudioEngine.EndingStyle = reason == .natural ? .crescendo : .single
        AudioEngine.shared.playEndingChime(
            ChimeCatalog.resolve(endChimeID), volume: chimeVolume, style: style
        )
        // 记录结算交给 journal（setup 是 setup，记录是记录）：够长静默落库，
        // 不够则挂起待用户决定，UI 层观察 journal.pendingConfirmation 弹框。
        SessionJournal.shared.finish(reason: reason, segments: segments)
        return segments
    }

    func reset() {
        stopTimers()
        phase = .idle
        clock = SessionClock(
            segmentStart: nil, accumulated: 0, finishedSegments: [],
            plannedDuration: nil, interval: nil
        )
        lastFiredIndex = 0
        tick = Date()
        syncIdleTimer()
        AudioEngine.shared.stopSilentKeepAlive()
        ReminderScheduler.disarm()
        LiveActivityController.shared.end()   // 幂等
    }

    // MARK: 结束确认（用户 2026-10-20 决策：LA 结束按钮与 App 内结束都不再直接结束）

    /// 结束确认挂起中。UI（RootView）观察此属性弹二次确认框，满足 FR-2.3。
    private(set) var pendingEndConfirmation = false

    /// 请求结束：只挂起，不执行。App 内结束按钮与 LA「打开 App 后确认」共用此入口。
    func requestEnd() {
        guard isActive else { return }
        pendingEndConfirmation = true
    }

    /// 用户取消：会话继续。同时清掉 LA 传来的待处理标志，避免残留。
    func cancelEnd() {
        pendingEndConfirmation = false
        MeditationEndIntent.clearPending()
    }

    /// 用户确认：走完整结束逻辑（单声收尾 + 落库 / 短会话弹框）。
    func confirmEnd() {
        guard pendingEndConfirmation else { return }
        pendingEndConfirmation = false
        MeditationEndIntent.clearPending()
        _ = end(reason: .manual)
    }

    // MARK: 跨启动恢复（用户 2026-10-20 新增）

    /// App 被杀后重启：内存状态全丢，但实时活动还在（系统持有）。
    /// 若存在 open 记录，还原 clock / phase / 配置，让 LA 的「结束」有对象可执行，
    /// 用户取消后会话也能正常继续。
    func restoreIfNeeded() {
        guard !isActive, let record = SessionJournal.shared.unfinishedRecord() else { return }
        // 只恢复「死时在跑」或「暂停过」的会话。两者皆无的 open 记录是残留
        // （如历史版本撤回失败留下的空壳），恢复它只会得到一场假暂停。
        guard record.segmentStart != nil || record.accumulated > 0 else {
            dbgLog("[restore] skipped empty open record \(record.id)")
            return
        }
        let segments = record.segments.flatMap {
            try? JSONDecoder().decode([TimedSegment].self, from: $0)
        } ?? []
        clock = SessionClock(
            segmentStart: record.segmentStart,
            accumulated: record.accumulated,
            finishedSegments: segments,
            plannedDuration: record.plannedDuration,
            interval: record.interval
        )
        chimeID = record.chimeID
        endChimeID = record.endChimeID
        ambientID = record.ambientID
        chimeVolume = record.chimeVolume
        ambientVolume = record.ambientVolume
        wasAutoAdjusted = record.wasAutoAdjusted
        tick = Date()
        // segmentStart 非 nil = 死时在跑；nil = 死时暂停
        phase = record.segmentStart != nil ? .running : .paused

        // 进程死后音频会话随之消亡，重起才能继续发声 / 守活
        AudioEngine.shared.beginSession(
            ambient: AmbientCatalog.resolve(record.ambientID),
            chimeVolume: record.chimeVolume,
            ambientVolume: record.ambientVolume
        )
        LiveActivityController.shared.start(clock: clock, summary: sessionSummary)
        syncIdleTimer()
        startUITimer()
        scheduleNextChime()
        dbgLog("[restore] recovered open session started at \(record.startedAt)")
    }

    /// App 回前台自检：重建消失的实时活动（系统 8 小时上限 / 用户误杀 App），
    /// 重排调度链（会话若已在挂起期间到头，这里会补一次自然结束）。
    func reconcileOnForeground() {
        guard isActive else {
            LiveActivityController.shared.end()
            return
        }
        LiveActivityController.shared.repairIfNeeded(clock: clock, summary: sessionSummary)
        tick = Date()
        scheduleNextChime()
    }

    // MARK: 前后台切换

    /// 转前台：恢复可能被杀的会话、停静音守护、清通知残留、按会话状态恢复常亮、
    /// 自愈实时活动与调度链。
    func enterForeground() {
        isInBackground = false
        restoreIfNeeded()      // App 被杀重启：先把会话找回来（无 open 记录则 no-op）
        AudioEngine.shared.stopSilentKeepAlive()
        ReminderScheduler.disarm()
        syncIdleTimer()
        reconcileOnForeground()
    }

    /// 转后台：调度链**继续跑** —— GCD 定时器不受锁屏节流影响，这是方案 B 的
    /// 前提；前台那套「撤 Timer、改通知」的互斥切换整体废除，双响隐患从结构上消失。
    ///
    /// 唯一要补的是「无背景音」场景：没有持续音频输出，系统会在几十秒内把 App
    /// 挂起，调度链随之停摆 —— 起一段循环数字静音守住音频会话即可。
    func enterBackground() {
        isInBackground = true
        syncIdleTimer()
        ReminderScheduler.disarm()
        guard phase == .running else { return }
        if ambientID == nil {
            AudioEngine.shared.beginSilentKeepAlive()
        }
    }

    // MARK: UI 心跳

    private func startUITimer() {
        uiTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handleTick() }
        }
        uiTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleTick() {
        tick = Date()
        guard phase == .running else { return }
        if clock.isFinished(at: tick) {
            end(reason: .natural)
            return
        }
        // 永久模式没有 targetEnd，岛/锁屏上显示的「已冥想时长」只能靠 App 推更新。
        // 每秒推会耗尽更新预算，每分钟推一次足够。
        if isPerpetual, tick.timeIntervalSince(lastIslandSync) >= 60 {
            lastIslandSync = tick
            LiveActivityController.shared.sync(clock: clock)
        }
    }

    // MARK: 间隔提示调度（方案 B：GCD 调度链）

    /// 「下一次事件」= min(下一间隔提示, 结束时刻)，一次只排一个，挂在私有队列的
    /// `DispatchSourceTimer` 上（leeway 100ms，±0.1 秒对钵音无感）。
    ///
    /// 主 RunLoop 的 Timer 在锁屏态被系统节流（真机实测：后台锁定完全不触发），
    /// GCD 定时器不受影响 —— App 活着时（背景音 / 静音守护保证），前台、后台、
    /// 锁屏三种状态走同一条链。暂停 / 继续 / App 被杀重开都从当前 elapsed 重算，
    /// 不靠 Timer 的周期累积。
    private func scheduleNextChime() {
        chimeSource?.cancel()
        chimeSource = nil
        guard phase == .running else { return }

        let now = Date()
        let nextReminder = IntervalSchedule.nextReminder(clock: clock, from: now)
        let endDate = clock.endDate(from: now)

        // 结束时刻优先：没有更早的间隔提示时，到点直接走自然结束
        // （结束音也由这条链触发，锁屏下照样播三声渐强）。
        let eventDate: Date
        let isEnd: Bool
        if let endDate, nextReminder?.date ?? .distantFuture >= endDate {
            eventDate = endDate
            isEnd = true
        } else if let reminder = nextReminder {
            eventDate = reminder.date
            isEnd = false
        } else {
            return   // 永久 + 无间隔：没有下一个事件
        }
        let index = nextReminder?.index ?? 0

        let source = DispatchSource.makeTimerSource(queue: chimeQueue)
        source.schedule(
            deadline: .now() + max(0, eventDate.timeIntervalSince(now)),
            leeway: .milliseconds(100)
        )
        source.setEventHandler { [weak self] in
            // 关键一跃：从后台队列 hop 回主线程播放。dispatch 到主队列是
            // run-loop *source* 而非 *timer*，锁屏态照常被处理 —— 这正是
            // 「主 RunLoop Timer 失灵但本方案可用」的根据。
            Task { @MainActor in
                guard let self else { return }
                if isEnd {
                    self.end(reason: .natural)
                } else {
                    self.fireInterval(index)
                }
            }
        }
        chimeSource = source
        source.resume()
    }

    private func fireInterval(_ index: Int) {
        guard phase == .running, index != lastFiredIndex else { return }
        lastFiredIndex = index
        AudioEngine.shared.playIntervalChime(ChimeCatalog.resolve(chimeID), volume: chimeVolume)
        // 自愈：下一发（或结束时刻）继续从当前 elapsed 反算，不靠 Timer 的周期
        tick = Date()
        scheduleNextChime()
    }

    private func stopTimers() {
        uiTimer?.invalidate(); uiTimer = nil
        chimeSource?.cancel(); chimeSource = nil
    }
}
