import AVFoundation
import Foundation

/// 音频中枢：提示音、背景音、试听预览、ducking、后台音频会话。
///
/// 设计要点：
/// - **不用 AVAudioEngine**。素材是 .m4a 采样，`AVAudioPlayer` 自己就处理好
///   「循环 / 音量渐变 / 后台播放」，引入引擎只会徒增复杂度。
/// - **单例**。音频会话是进程级资源， App / Widget / AppDelegate 都从同一处取。
/// - **试听与会话是两套状态**。`preview*` 只在非会话期可用，不会打乱正在进行的冥想。
/// - **ducking 用 token 管理**。提示音密集时后一次的恢复会取消前一次的挂起，
///   不会出现「音量被提前拉回来」。
@MainActor
final class AudioEngine {

    static let shared = AudioEngine()

    // MARK: - 配置

    private var chimeVolume: Double = 0.8
    private var ambientVolume: Double = 0.5

    /// 提示音响起时，背景音压到这个比例。
    private let duckLevel: Double = 0.12

    /// 结束音三声渐强（Q6 默认收尾）：各声音量与间隔。
    private let endingLevels: [Double] = [0.45, 0.72, 1.0]
    private let endingGap: TimeInterval = 1.6

    // MARK: - 状态

    private var ambientPlayer: AVAudioPlayer?
    /// 单发播放器池（间隔音、结束音、试听）。重叠播放时各占一个，播完自动清理。
    /// 不共享 player —— 结束音三声要叠在一起才能形成渐强。
    private var transientPlayers: [AVAudioPlayer] = []

    /// 静音守护播放器：无背景音的会话退后台时循环播放数字静音，只为
    /// 「音频会话在播」这个事实 —— 没有它，系统会在几十秒内挂起 App，
    /// GCD 调度链随之停摆（方案 B 的前提是 App 活着）。
    private var keepAlivePlayer: AVAudioPlayer?

    /// 试听中的背景音 id；`nil` 表示没有在试听背景音。
    private var previewingAmbientID: String?

    /// 正式会话是否占用音频。会话期禁用试听，避免打乱正在进行的冥想。
    private(set) var isInSession = false
    private var isSessionActive = false
    private var duckToken = 0

    private init() {
        configureSession()
    }

    // MARK: - 音频会话

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers：不打断用户正在听的音乐 / 播客（冥想常伴随自己的歌单）。
        // 不用 .duckOthers —— 那是让「别人」降；我们要的是提示音时「自己的背景音」降。
        // 不显式加蓝牙选项：.playback 默认就走 A2DP 高音质路由，
        // 加 allowBluetoothHFP 反而允许把音质降到通话档。
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        // 不在这里 setActive —— 等真正要出声时再激活，避免一开始就抢音频焦点。
    }

    private func activateIfNeeded() {
        guard !isSessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        isSessionActive = true
    }

    private func deactivate() {
        guard isSessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isSessionActive = false
    }

    // MARK: - 素材定位

    /// 先找 bundle 根目录（当前 `type: resources` 平铺入包），再退到子目录
    /// —— 将来若改回 `type: folder` 组织成 chimes/ 与 ambient/ 也能工作。
    private func url(forResource name: String, subdirectory: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "m4a") { return url }
        return Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: subdirectory)
    }

    /// 只为读时长加载一次。素材 60–76KB，代价可忽略；换来的是 ducking 时长精确覆盖。
    private func duration(ofResource name: String, subdirectory: String) -> TimeInterval {
        guard let url = url(forResource: name, subdirectory: subdirectory) else {
            dbgLog("[audio] MISSING chime file: \(name).m4a")
            return 3.0
        }
        let d = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
        return d > 0.2 ? d : 3.0
    }

    // MARK: - 试听预览（非会话期）

    /// 选提示音时播一下。会打断当前正在试听的任何声音。
    func previewChime(_ chime: Chime, volume: Double) {
        guard !isInSession else { return }
        chimeVolume = volume
        previewingAmbientID = nil
        ambientPlayer?.stop()          // 打断正在试听的背景音
        ambientPlayer = nil
        playOneShot(chime, volume: volume)
    }

    /// 选背景音时播一下（循环，播多久都行）。会打断正在试听的提示音。
    func previewAmbient(_ ambient: Ambient, volume: Double) {
        guard !isInSession else { return }
        ambientVolume = volume
        transientPlayers.forEach { $0.stop() }
        transientPlayers.removeAll()
        previewingAmbientID = ambient.id
        startAmbientLoop(ambient, volume: volume)
    }

    /// 拖动背景音音量条时调用：
    /// - 正在试听的就是这个背景音 → **只改音量，不重播**
    /// - 正在放的是别的声音（提示音 / 另一个背景音 / 无）→ **切换成播放这个背景音**
    func adjustAmbientVolume(id: String?, volume: Double) {
        ambientVolume = volume
        if isInSession {
            ambientPlayer?.volume = Float(volume)
            return
        }
        guard let id, let ambient = AmbientCatalog.resolve(id) else {
            // 「无」：停掉背景音试听，只记住音量
            ambientPlayer?.stop()
            ambientPlayer = nil
            previewingAmbientID = nil
            deactivateIfIdle()
            return
        }
        if previewingAmbientID == id {
            ambientPlayer?.setVolume(Float(volume), fadeDuration: 0.06)
        } else {
            previewAmbient(ambient, volume: volume)
        }
    }

    /// 拖动提示音音量条时实时生效（不重播；放手时由界面另播一次试听）。
    func adjustChimeVolume(volume: Double) {
        chimeVolume = volume
        guard !isInSession else { return }
        transientPlayers.forEach { $0.volume = Float(volume) }
    }

    // MARK: - 会话期

    func beginSession(ambient: Ambient?, chimeVolume: Double, ambientVolume: Double) {
        stopAllPlayers()
        stopSilentKeepAlive()
        previewingAmbientID = nil
        self.chimeVolume = chimeVolume
        self.ambientVolume = ambientVolume
        isInSession = true
        activateIfNeeded()
        if let ambient { startAmbientLoop(ambient, volume: ambientVolume) }
    }

    /// 间隔提示音：播一声，同时把背景音压低，播完平滑恢复。
    func playIntervalChime(_ chime: Chime, volume: Double) {
        guard isInSession else { return }
        duckFor(duration(ofResource: chime.filename, subdirectory: "chimes") + 0.2)
        playOneShot(chime, volume: volume)
    }

    /// 结束音的两种形态（用户 2026-10-18 决策：手动结束单声、自然结束渐强）。
    enum EndingStyle: Sendable {
        /// 三声渐强（Q6 定稿的自然收尾）。
        case crescendo
        /// 单声全音量 —— 用户主动点「结束」时用，中途收场不需要仪式感。
        case single
    }

    /// 结束音：按形态播放，全程压低背景音。
    ///
    /// 会话标志立即释放（让用户能马上试听下一个），但音频会话**延后关闭** ——
    /// `setActive(false)` 会把尾声直接掐掉。
    func playEndingChime(_ chime: Chime, volume: Double, style: EndingStyle) {
        switch style {
        case .crescendo:
            let span = duration(ofResource: chime.filename, subdirectory: "chimes")
                + TimeInterval(endingLevels.count - 1) * endingGap
            isInSession = false
            duckFor(span + 0.3)
            for (index, level) in endingLevels.enumerated() {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Double(index) * self.endingGap * 1_000_000_000))
                    self.playOneShot(chime, volume: volume * level)
                }
            }
            windDownSession(after: span + 0.4)

        case .single:
            let span = duration(ofResource: chime.filename, subdirectory: "chimes")
            isInSession = false
            duckFor(span + 0.3)
            playOneShot(chime, volume: volume)
            windDownSession(after: span + 0.4)
        }
    }

    /// 收尾音播完后：淡出并停止背景音、停掉静音守护、释放音频会话。
    ///
    /// 顺带修掉一个旧问题：以前结束音播完后背景音会一直循环下去没人停 ——
    /// `deactivateIfIdle` 看到 ambient 还在播就跳过释放，而没有任何地方停
    /// ambient，用户感知为「结束了背景音还在响」。现在收尾即收尾。
    ///
    /// `isInSession` 双重守卫：用户若在尾声放完前抢先开了新会话，整体跳过 ——
    /// 不能把新会话的背景音一起停了、更不能把新会话的音频会话关掉。
    private func windDownSession(after delay: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !self.isInSession else { return }
            self.stopSilentKeepAlive()
            self.ambientPlayer?.setVolume(0, fadeDuration: 0.7)
            try? await Task.sleep(nanoseconds: UInt64(0.8 * 1_000_000_000))
            guard !self.isInSession else { return }
            self.ambientPlayer?.stop()
            self.ambientPlayer = nil
            self.deactivateIfIdle()
        }
    }

    // MARK: - 静音守护（无背景音时的后台保活）

    /// 起一段循环数字静音，守住音频会话。只在「会话运行中 + 无背景音 + 退后台」
    /// 时由 SessionController 调用；回前台 / 会话结束即停。
    func beginSilentKeepAlive() {
        guard keepAlivePlayer == nil else { return }
        guard let url = Bundle.main.url(forResource: "keepalive-silence", withExtension: "wav") else {
            dbgLog("[audio] MISSING keepalive-silence.wav (bundle 内未找到，检查资源是否入包)")
            return
        }
        activateIfNeeded()
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.volume = 0        // 真静音；系统只看「会话在播」，不看内容
        player?.play()
        keepAlivePlayer = player
        dbgLog("[audio] silent keep-alive started: playing=\(player?.isPlaying == true) sessionActive=\(isSessionActive)")
    }

    func stopSilentKeepAlive() {
        guard keepAlivePlayer != nil else { return }
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
    }

    // MARK: - 停止

    /// 停止一切播放并（若无会话占用）释放音频会话。
    /// 离开设置页、用户选「无背景音」时调用。
    ///
    /// **会话期一律不动**（问题 1 根因，真机验证）：点「开始」时 `start()` 先起播
    /// 背景音，紧接着 SwiftUI 因 `phase` 变化重绘、SetupView 移除触发 `onDisappear`
    /// —— 两个动作紧邻发生。若没有这道守卫，「离开设置页停试听」会把
    /// `beginSession` 刚起播的背景音一起停掉，用户感知为「开始计时后没有背景音，
    /// 只在点开始一瞬间响了一下」。会话音频的停放手由 `end()` 与中断处理负责，
    /// 不经过这里。
    func quietDown() {
        guard !isInSession else {
            dbgLog("[audio] quietDown ignored: session in progress")
            return
        }
        stopAllPlayers()
        previewingAmbientID = nil
        deactivateIfIdle()
    }

    private func stopAllPlayers() {
        ambientPlayer?.stop()
        ambientPlayer = nil
        transientPlayers.forEach { $0.stop() }
        transientPlayers.removeAll()
        duckToken += 1          // 取消挂起的 ducking 恢复
    }

    // MARK: - 播放原语

    private func startAmbientLoop(_ ambient: Ambient, volume: Double) {
        guard let url = url(forResource: ambient.filename, subdirectory: "ambient") else {
            dbgLog("[audio] MISSING ambient file: \(ambient.filename).m4a (bundle 内未找到，检查资源是否入包)")
            return
        }
        activateIfNeeded()
        ambientPlayer?.stop()
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1      // 素材已做首尾交叠，循环点无接缝
        player?.volume = Float(min(max(volume, 0), 1))
        player?.play()
        ambientPlayer = player
        dbgLog("[audio] ambient '\(ambient.filename)' started: playing=\(player?.isPlaying == true) duration=\(player?.duration ?? -1)s volume=\(volume) sessionActive=\(isSessionActive)")
    }

    private func playOneShot(_ chime: Chime, volume: Double) {
        guard let url = url(forResource: chime.filename, subdirectory: "chimes") else {
            dbgLog("[audio] MISSING chime file: \(chime.filename).m4a (bundle 内未找到，检查资源是否入包)")
            return
        }
        activateIfNeeded()
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = Float(min(max(volume, 0), 1))
        player?.play()
        if let player { transientPlayers.append(player) }
        transientPlayers.removeAll { !$0.isPlaying }
        dbgLog("[audio] chime '\(chime.filename)' fired: playing=\(player?.isPlaying == true) duration=\(player?.duration ?? -1)s volume=\(volume)")
    }

    // MARK: - ducking

    /// 压低背景音，`span` 秒后平滑恢复。
    ///
    /// token 机制：连续多次调用时，只有最后一次的恢复会真正生效 ——
    /// 否则前一次挂起的恢复会把音量提前拉回来。
    private func duckFor(_ span: TimeInterval) {
        duckToken += 1
        let token = duckToken
        ambientPlayer?.setVolume(Float(ambientVolume * duckLevel), fadeDuration: 0.12)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(span * 1_000_000_000))
            guard token == self.duckToken else { return }
            self.ambientPlayer?.setVolume(Float(self.ambientVolume), fadeDuration: 0.7)
        }
    }

    // MARK: - 中断（来电、其他 App 抢焦点）

    func handleInterruption(began: Bool) {
        guard isInSession else { return }
        if began {
            ambientPlayer?.pause()
            keepAlivePlayer?.pause()
            transientPlayers.forEach { $0.pause() }
        } else {
            // 系统会在中断结束后替我们重新激活 playback 会话，直接续播即可
            ambientPlayer?.play()
            keepAlivePlayer?.play()
        }
    }

    // MARK: - 收尾

    /// 没有会话占用、也没有任何声音在播（含静音守护）时，才释放音频会话。
    private func deactivateIfIdle() {
        guard !isInSession else { return }
        guard transientPlayers.allSatisfy({ !$0.isPlaying }) else { return }
        guard ambientPlayer?.isPlaying != true else { return }
        guard keepAlivePlayer?.isPlaying != true else { return }
        deactivate()
    }
}
