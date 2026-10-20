import SwiftData
import Foundation

// MARK: - 会话记录

/// 一次冥想。v1 只落库不展示；记录查看页属 v1.1。
///
/// 2026-10-19 起记录页落地（第二阶段），本模型同时承担两个职责：
/// 1. **已完成的记录**：`endedAt` 非 nil，记录页的数据源；
/// 2. **未闭合的会话**（App 被杀时留下的 open 记录）：`endedAt == nil`，
///    存有时钟快照，App 重启后靠它恢复会话（`SessionController.restoreIfNeeded`）。
@Model
final class SessionRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var plannedDuration: TimeInterval?
    var interval: TimeInterval?
    var wasAutoAdjusted: Bool
    var chimeID: String
    var endChimeID: String
    var ambientID: String?
    var mindfulWritten: Bool
    var billableSeconds: TimeInterval

    // MARK: 跨启动恢复快照（open 记录专用，结束后清零）

    /// 之前所有已完成段的累计秒数。
    var accumulated: TimeInterval = 0
    /// 当前运行段起点。nil = 死时处于暂停态。
    var segmentStart: Date?
    /// 已完成段数组的 JSON（`TimedSegment` 已 Codable）。
    var segments: Data?
    /// 结束方式："natural" / "manual" / "discarded"（短会话被用户放弃记录）。
    var endReason: String?
    /// 作废标记。短会话询问后用户选「不记录」→ 记录留在库里但不进任何统计与列表。
    /// 不用 delete 撤回 —— SwiftData 对带 relationship 的模型 delete + save 在本环境
    /// 稳定失效（实测：save 静默失败、记录原样留在库里），改标记是可靠等价物。
    var isDiscarded: Bool = false

    // MARK: 音量（恢复用）

    var chimeVolume: Double = 0.8
    var ambientVolume: Double = 0.5

    @Relationship(deleteRule: .cascade, inverse: \VitalRecord.session)
    var vitals: [VitalRecord] = []

    init(
        id: UUID = UUID(),
        startedAt: Date,
        plannedDuration: TimeInterval?,
        interval: TimeInterval?,
        wasAutoAdjusted: Bool = false,
        chimeID: String,
        endChimeID: String,
        ambientID: String?,
        mindfulWritten: Bool = false,
        billableSeconds: TimeInterval = 0,
        chimeVolume: Double = 0.8,
        ambientVolume: Double = 0.5
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = nil
        self.plannedDuration = plannedDuration
        self.interval = interval
        self.wasAutoAdjusted = wasAutoAdjusted
        self.chimeID = chimeID
        self.endChimeID = endChimeID
        self.ambientID = ambientID
        self.mindfulWritten = mindfulWritten
        self.billableSeconds = billableSeconds
        self.chimeVolume = chimeVolume
        self.ambientVolume = ambientVolume
    }
}

// MARK: - 体征样本

/// 一条 Heart Rate / HRV 样本，对应 HealthKit 里的一条 `HKQuantitySample`。
@Model
final class VitalRecord {
    @Attribute(.unique) var dedupeKey: String
    var kind: String
    var value: Double
    var startDate: Date
    var endDate: Date
    var sourceID: String?
    var session: SessionRecord?

    init(reading: VitalReading) {
        self.dedupeKey = reading.dedupeKey
        self.kind = reading.kind.rawValue
        self.value = reading.value
        self.startDate = reading.startDate
        self.endDate = reading.endDate
        self.sourceID = reading.sourceID
    }

    var asReading: VitalReading {
        VitalReading(
            kind: VitalKind(rawValue: kind) ?? .heartRate,
            value: value,
            startDate: startDate,
            endDate: endDate,
            sourceID: sourceID
        )
    }
}

// MARK: - 容器

enum SessionStore {
    static let container: ModelContainer = {
        let schema = Schema([SessionRecord.self, VitalRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, migrationPlan: nil, configurations: configuration)
        } catch {
            fatalError("SwiftData 容器创建失败：\(error)")
        }
    }()
}
