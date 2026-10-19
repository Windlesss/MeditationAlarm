import Foundation

// MARK: - 指标类型

public enum VitalKind: String, Codable, CaseIterable, Sendable, Hashable {
    case heartRate
    case hrvSDNN

    public var displayName: String {
        switch self {
        case .heartRate: return "心率"
        case .hrvSDNN: return "HRV"
        }
    }

    /// 单位后缀，画图时贴在数值旁。
    public var unitLabel: String {
        switch self {
        case .heartRate: return "bpm"
        case .hrvSDNN: return "ms"
        }
    }

    /// 合理的取值范围。超出即视为脏样本丢弃。
    public var plausibleRange: ClosedRange<Double> {
        switch self {
        case .heartRate: return 20...250
        case .hrvSDNN: return 1...400
        }
    }
}

// MARK: - 单条样本

/// 一次体征读数 —— 对应 HealthKit 里的一条 `HKQuantitySample`。
public struct VitalReading: Equatable, Sendable, Hashable {
    public let kind: VitalKind
    public let value: Double
    public let startDate: Date
    public let endDate: Date
    /// HealthKit 样本的稳定标识（`HKObject.uuid`）。去重的**主键**。
    public let sourceID: String?

    public init(
        kind: VitalKind,
        value: Double,
        startDate: Date,
        endDate: Date = Date(),
        sourceID: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.startDate = startDate
        self.endDate = endDate
        self.sourceID = sourceID
    }

    /// 去重键。有 `sourceID` 就用它；没有才退化到「时间 + 数值」组合。
    /// SwiftData 侧用它做唯一索引。
    public var dedupeKey: String {
        if let sourceID, !sourceID.isEmpty { return "u:\(sourceID)" }
        let s = startDate.timeIntervalSinceReferenceDate.bitPattern
        let e = endDate.timeIntervalSinceReferenceDate.bitPattern
        let v = value.bitPattern
        return "d:\(kind.rawValue):\(s):\(e):\(v)"
    }

    /// 脏样本过滤：非有限值、超出该指标合理区间的样本直接丢弃（含 HealthKit 异常返回的 0）。
    /// 返回 false 的样本不入库 —— 因此「全零导致隐藏」在实现上退化为「空导致隐藏」。
    public var isValid: Bool {
        value.isFinite && kind.plausibleRange.contains(value)
    }
}

// MARK: - 画点

/// 图上一点。X 轴是**相对冥想起点的秒数**，不是绝对时间。
public struct VitalPoint: Equatable, Sendable, Hashable {
    public let offsetSeconds: TimeInterval
    public let value: Double
}

// MARK: - 区块可见性

/// FR-10.5：由数据驱动的渲染决策，**没有 ADC 开关**。
public enum VitalPresentation: Equatable, Sendable {
    /// 没有可用数据 —— 整块（含标题）不渲染。
    case hidden
    /// 只有一个点 —— 画不成曲线，显示单值。
    case single(value: Double)
    /// 两个及以上 —— 画曲线。
    case series([VitalPoint])
}

// MARK: - 采样簿

/// 会话期间的体征采样集合。
///
/// **去重是命门。** Apple Watch 静息时可能 10 分钟才写一条 HRV，而我们去查询的频率是 30 秒 ——
/// 同一条样本会被反复捞到 20 次。不去重的话画出来是一条虚假的平线，看起来像「HRV 全程稳定」，
/// 实际那条曲线只对应一次真实测量。
///
/// 这里按 HealthKit 样本 uuid 去重，保证**一条真实样本在图上只有一个点**。
public struct VitalsBook: Sendable, Equatable {

    private(set) public var readings: [VitalReading] = []
    private var seen: Set<String> = []

    public init() {}

    public var isEmpty: Bool { readings.isEmpty }

    /// 入库一条。返回 `true` 表示这是**新**样本（被采纳）。
    @discardableResult
    public mutating func ingest(_ reading: VitalReading) -> Bool {
        guard reading.isValid else { return false }
        let key = reading.dedupeKey
        guard !seen.contains(key) else { return false }
        seen.insert(key)
        readings.append(reading)
        return true
    }

    /// 批量入库，返回新采纳的条数。
    @discardableResult
    public mutating func ingest(_ new: [VitalReading]) -> Int {
        var count = 0
        for r in new where ingest(r) { count += 1 }
        return count
    }

    public func readings(of kind: VitalKind) -> [VitalReading] {
        readings.filter { $0.kind == kind }.sorted { $0.startDate < $1.startDate }
    }

    // MARK: 渲染投影

    /// 返回该指标在小结页该怎么呈现。sessionStart 之前或 NaN 的样本会被排除。
    public func presentation(
        of kind: VitalKind,
        sessionStart: Date,
        sessionEnd: Date? = nil
    ) -> VitalPresentation {
        let all = readings(of: kind).filter {
            $0.startDate >= sessionStart && (sessionEnd == nil || $0.startDate <= sessionEnd!)
        }
        guard !all.isEmpty else { return .hidden }
        guard all.count > 1 else { return .single(value: all[0].value) }

        let points = all.map {
            VitalPoint(offsetSeconds: $0.startDate.timeIntervalSince(sessionStart), value: $0.value)
        }
        return .series(points)
    }

    /// 点数（供「4 个点」这样的文案使用）。
    public func count(of kind: VitalKind) -> Int { readings(of: kind).count }
}
