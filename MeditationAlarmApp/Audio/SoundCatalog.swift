import Foundation

// MARK: - 提示音

/// `Resources/Audio/chimes/` 下的素材。 filename 直接对应 bundle 里的文件名。
public struct Chime: Identifiable, Hashable, Sendable {
    public let id: String          // 稳定代号，存设置用
    public let filename: String
    public let name: String
    public let family: Family

    public enum Family: String, Sendable { case dong, ding }
}

public enum ChimeCatalog {
    public static let all: [Chime] = [
        Chime(id: "bowl-deep-01", filename: "bowl-deep-01", name: "颂钵 · 深", family: .dong),
        Chime(id: "bowl-deep-02", filename: "bowl-deep-02", name: "颂钵 · 清", family: .dong),
        Chime(id: "bowl-large-hit", filename: "bowl-large-hit", name: "大钵", family: .dong),
        Chime(id: "bowl-small", filename: "bowl-small", name: "小藏钵", family: .dong),
        Chime(id: "bowl-small-hit", filename: "bowl-small-hit", name: "小钵敲击", family: .dong),
        Chime(id: "chime-tubebell", filename: "chime-tubebell", name: "管钟", family: .ding),
        Chime(id: "rin-strike", filename: "rin-strike", name: "引磬", family: .ding),
        Chime(id: "rin-friction", filename: "rin-friction", name: "引磬 · 摩", family: .ding),
    ]

    public static let `default` = all[0]

    public static func resolve(_ id: String) -> Chime {
        all.first { $0.id == id } ?? `default`
    }
}

// MARK: - 背景音

public struct Ambient: Identifiable, Hashable, Sendable {
    public let id: String
    public let filename: String
    public let name: String
}

public enum AmbientCatalog {
    public static let all: [Ambient] = [
        Ambient(id: "rain", filename: "rain", name: "雨声"),
        Ambient(id: "rain-window", filename: "rain-window", name: "雨打窗"),
        Ambient(id: "ocean", filename: "ocean", name: "海浪"),
        Ambient(id: "sea", filename: "sea", name: "海潮"),
        Ambient(id: "water-flow", filename: "water-flow", name: "流水"),
        Ambient(id: "stream", filename: "stream", name: "溪流"),
        Ambient(id: "forest-birds", filename: "forest-birds", name: "林间鸟鸣"),
    ]

    /// 无背景音。
    public static let off = Ambient(id: "none", filename: "", name: "无")

    public static func resolve(_ id: String?) -> Ambient? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}
