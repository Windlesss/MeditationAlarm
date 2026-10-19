import SwiftUI

// MARK: - 色板

/// 宣纸 · 青瓷 · 水墨 —— 详见 `DESIGN.md`。
///
/// 放在 Shared 是因为 App 和 Widget Extension 都要用。
/// **注意**：灵动岛与锁屏是纯黑底，必须走深色变体，不能直接用 App 的浅色。
public enum Palette {

    // MARK: App 浅色（宣纸）

    public static let paper = Color(hex: 0xF7F5F1)          // 底色
    public static let porcelain = Color(hex: 0xFFFDFA)      // 卡片
    public static let ink = Color(hex: 0x2B2A28)            // 主文字
    public static let inkSub = Color(hex: 0x6E6B66)         // 次要
    public static let inkTertiary = Color(hex: 0x9A968F)    // 三级
    public static let hairline = Color(hex: 0xE2DED6)       // 分割线
    public static let celadon = Color(hex: 0x7E9E92)        // 青瓷（强调）
    public static let celadonBg = Color(hex: 0xE6EFEB)      // 青瓷底（选中胶囊）
    public static let ochre = Color(hex: 0xB08D6A)          // 淡赭（HRV）
    public static let clay = Color(hex: 0xA85C50)           // 砖红（结束）

    // MARK: 深色变体（灵动岛 / 锁屏）

    public static let islandBg = Color(hex: 0x1C1B19)
    public static let islandText = Color(hex: 0xE8E4DC)
    public static let islandSub = Color(hex: 0x9C968C)
    public static let celadonOnDark = Color(hex: 0x8FB3A6)

    // MARK: 排版

    /// 计时主数字。锁屏场景另用 `timerMonospaced`。
    public static let timerFont = Font.system(size: 72, weight: .thin, design: .default)

    public static func fonts(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - 数字 jitter 防护

public extension View {
    /// 所有会跳动的数字都要套上 —— 等宽数字保证秒位变化时整体不左右抖，
    /// 在这种留白很大的浅色界面里，抖动会格外明显。
    func stableDigits() -> some View {
        self.monospacedDigit()
    }
}

// MARK: - 计时字符串格式

public enum TimeFormatter {
    /// mm:ss；超过 1 小时变 h:mm:ss。
    public static func string(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// 用于「已冥想 28 分钟」这类文案。
    public static func minutesString(_ interval: TimeInterval) -> String {
        let m = Int((interval / 60).rounded())
        return "\(m) 分钟"
    }
}

// MARK: - hex 便利构造

public extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
