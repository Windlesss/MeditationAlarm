import SwiftUI
import SwiftData

@main
struct MeditationAlarmApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var controller = SessionController()
    /// 必须由 App 持有 —— DarwinListener 靠 `Unmanaged` 裸指针自持，没人留它就会被释放。
    @State private var controlListener: DarwinListener?

    /// v1 引入 SwiftData 存储会话与体征样本；记录查看页属 v1.1。
    let container = SessionStore.container

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let controller = SessionController()
        _controller = State(initialValue: controller)

        // 灵动岛 / 锁屏按钮的落点。Widget 进程里只能跨进程发信号，
        // 真正干活的是这里 —— 少了这个监听，岛上的「暂停」按了没反应。
        // 「结束」已改走 MeditationEndIntent（打开 App 后弹确认，见 RootView），
        // 这条 Darwin 通道只处理暂停 / 继续。
        _controlListener = State(initialValue: DarwinListener { command in
            Task { @MainActor in
                switch command {
                case .togglePause:
                    switch controller.phase {
                    case .running: controller.pause()
                    case .paused: controller.resume()
                    default: break
                    }
                case .end:
                    break
                }
            }
        })

        // 跨启动恢复：App 被杀后重启，内存状态全丢但实时活动还在。
        // 这里先把会话找回来，LA 的「结束」才有对象可执行。
        Task { @MainActor in
            controller.restoreIfNeeded()
        }

        #if DEBUG
        // 自测钩子：`xcrun simctl launch <udid> com.windlessd.MeditationAlarm -selfTest`
        // 会自动开一个 2 分钟 / 间隔 1 分钟 / 雨声背景音的会话，
        // 用于不依赖手点就能验证「实时活动 + 后台音频」整条链路。
        // release 包里不存在这段。走 dbgLog 而非 print —— print 到管道是块缓冲，log show 抓不到。
        dbgLog("[selfTest] arguments = \(CommandLine.arguments.joined(separator: " "))")
        if CommandLine.arguments.contains("-selfTest") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                // 守卫：恢复链路或异常重复触发时，不覆盖进行中的会话
                guard controller.phase == .idle else {
                    dbgLog("[selfTest] skipped, phase = \(controller.phase)")
                    return
                }
                dbgLog("[selfTest] starting, phase = \(controller.phase)")
                controller.start(.init(
                    plannedDuration: 35,
                    interval: 12,
                    chimeID: ChimeCatalog.default.id,
                    endChimeID: ChimeCatalog.default.id,
                    ambientID: "rain",
                    wasAutoAdjusted: false
                ))
                dbgLog("[selfTest] started, phase = \(controller.phase), islandActive = \(LiveActivityController.shared.isActive)")
            }
        }
        // 长会话自测钩子：`-selfTestLong` 开一场 100 秒 / 间隔 30 秒 / 雨声的会话，
        // 超过记录阈值 → 走「静默落库 + 正念写入 + 小结页」完整路径
        // （35 秒的 -selfTest 只覆盖短会话弹框）。
        if CommandLine.arguments.contains("-selfTestLong") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard controller.phase == .idle else {
                    dbgLog("[selfTestLong] skipped, phase = \(controller.phase)")
                    return
                }
                dbgLog("[selfTestLong] starting")
                controller.start(.init(
                    plannedDuration: 100,
                    interval: 30,
                    chimeID: ChimeCatalog.default.id,
                    endChimeID: ChimeCatalog.default.id,
                    ambientID: "rain",
                    wasAutoAdjusted: false
                ))
            }
        }
        // 记录页验证钩子：`-seedRecords` 造 9 条跨日期的历史记录（含今天两条），
        // 用于不依赖真实冥想就能检查统计 / 日历热力图 / 列表 / 详情 / 删除。
        if CommandLine.arguments.contains("-seedRecords") {
            Task { @MainActor in
                SessionJournal.shared.seedDemoRecords()
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller)
                .modelContainer(container)
                .onChange(of: scenePhase) { _, new in
                    Task { @MainActor in
                        switch new {
                        case .active:
                            // 前台：停静音守护、清通知残留、恢复常亮、自愈实时活动
                            controller.enterForeground()
                            // 正念写入前台重试：被拒 / 写失败的记录，在用户改主意授权后补写
                            SessionJournal.shared.retryMindfulWrites()
                            // LA「结束」按钮的落点：intent 已把 App 带到前台并留下标志，
                            // 这里消费它 → 弹二次确认（用户 2026-10-20 决策）。
                            if MeditationEndIntent.consumePending(), controller.isActive {
                                controller.requestEnd()
                            }

                        case .background:
                            // 后台：调度链继续跑（GCD 不受锁屏节流影响）；
                            // 无背景音的会话在这里起静音守护保活
                            controller.enterBackground()

                        case .inactive:
                            break

                        @unknown default:
                            break
                        }
                    }
                }
        }
    }
}
