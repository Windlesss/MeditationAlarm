import Foundation
import WatchConnectivity

/// Apple Watch 配对状态（第三阶段 v3a，授权分流用）。
///
/// 唯一的「硬件在位」查询就是 `WCSession.isPaired`：
/// - HealthKit 侧没有「有没有手表」的接口，只能查「有没有样本」——
///   而静息时手表可能几小时不写一条，「没样本」≠「没手表」；
/// - 样本的 `sourceRevision.device` 能识别是不是 Watch，但同样只反映数据不反映硬件。
///
/// **检测只决定授权范围，不预测数据有无** —— 手表戴着但整场没写样本，
/// 照样走 FR-10.5 全零隐藏。
@MainActor
final class WatchPresence: NSObject, WCSessionDelegate {

    static let shared = WatchPresence()

    private override init() {
        super.init()
        guard WCSession.isSupported() else {
            dbgLog("[watch] WCSession unsupported (iPad?)")
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// 激活完成前保守返回 `true` —— 宁可多请求读权限（授权页长一点），
    /// 不可漏请求（漏了配对手表用户永远拿不到心率数据）。激活通常在
    /// App 启动后 1 秒内完成，而授权发生在首次会话开始时，竞态窗口极小。
    var isPaired: Bool {
        guard WCSession.isSupported() else { return false }
        guard WCSession.default.activationState == .activated else { return true }
        return WCSession.default.isPaired
    }

    // MARK: WCSessionDelegate
    //
    // 协议要求是 nonisolated（回调可能来自任意队列），本类是 @MainActor ——
    // 用 nonisolated 满足要求。回调里只做日志与属性读取，不碰主线程状态。

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        dbgLog("[watch] activation state = \(activationState.rawValue), isPaired = \(session.isPaired), error = \(String(describing: error))")
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        dbgLog("[watch] watch state changed, isPaired = \(session.isPaired)")
    }

    // MARK: Required stubs for protocol conformance (iPhone only)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        // No-op: required for protocol conformance
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // No-op: required for protocol conformance
    }
}
