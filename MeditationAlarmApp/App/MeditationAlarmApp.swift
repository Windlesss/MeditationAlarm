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
        // 真正干活的是这里 —— 少了这个监听，岛上的「暂停 / 结束」按了没反应。
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
                    controller.end(reason: .manual)
                }
            }
        })

        #if DEBUG
        // 自测钩子：`xcrun simctl launch <udid> com.windlessd.MeditationAlarm -selfTest`
        // 会自动开一个 2 分钟 / 间隔 1 分钟 / 雨声背景音的会话，
        // 用于不依赖手点就能验证「实时活动 + 后台音频」整条链路。
        // release 包里不存在这段。走 dbgLog 而非 print —— print 到管道是块缓冲，log show 抓不到。
        dbgLog("[selfTest] arguments = \(CommandLine.arguments.joined(separator: " "))")
        if CommandLine.arguments.contains("-selfTest") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
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
