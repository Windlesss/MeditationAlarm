import AVFoundation
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        dbgLog("[boot] didFinishLaunching, args=\(CommandLine.arguments.joined(separator: " "))")
        // 音频中断：来电、其他 App 抢音频焦点。中断结束后由引擎续播背景音。
        //
        // 注册在这里而不是 AudioEngine 内部 —— AppDelegate 是进程级单例、不会 deinit，
        // 不碰 `@MainActor` 类的 deinit 隔离问题（见 SessionController 里那段注释）。
        NotificationCenter.default.addObserver(
            forName: AVFoundation.AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                AudioEngine.shared.handleInterruption(began: type == .began)
            }
        }
        return true
    }
}
