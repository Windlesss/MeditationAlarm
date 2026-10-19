import Foundation

/// 诊断日志。**只在 Debug 构建里存在**，release 包里整段被编译掉，零开销。
///
/// 用 `@autoclosure` 而非直接传 String —— 字符串插值因此不会在 release 里求值。
///
/// ```swift
/// dbgLog("[audio] chime \\(name) fired")
/// ```
func dbgLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    NSLog("%@", message())
    #endif
}
