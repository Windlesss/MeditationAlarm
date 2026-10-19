import SwiftData
import Foundation

// MARK: - 会话记录

/// 一次冥想。v1 只落库不展示；记录查看页属 v1.1。
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
        billableSeconds: TimeInterval = 0
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
