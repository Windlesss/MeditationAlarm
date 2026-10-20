import SwiftUI

/// 本次小结页（第三阶段 v3a，用户 2026-10-20 决策）。
///
/// 呈现时机：结束弹框（短会话记录确认）之后、且本场有健康数据时**轻推一格**，
/// 右上角「完成」一划即走；历史记录的小结在详情页回看。
/// 无健康数据时整个页面不呈现（由 RootView 判断）—— 不留空页。
struct SessionSummaryView: View {
    let record: SessionRecord

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    durationHeader
                    if !record.vitals.isEmpty {
                        RecordVitalsSections(record: record)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
            .background(Palette.paper)
            .navigationTitle("本次小结")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.celadon)
                }
            }
        }
    }

    // MARK: 时长头部

    private var durationHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(record.billableSeconds / 60))")
                    .font(.system(size: 36, weight: .thin))
                    .foregroundStyle(Palette.ink)
                    .stableDigits()
                Text("分钟")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.inkSub)
            }
            Text(timeRange)
                .font(.system(size: 12))
                .foregroundStyle(Palette.inkTertiary)
                .stableDigits()
            Text(record.endReason == "natural" ? "自然结束" : "手动结束")
                .font(.system(size: 12))
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    private var timeRange: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: record.startedAt)
        let end = record.endedAt.map { formatter.string(from: $0) } ?? "—"
        return "\(start) – \(end)"
    }
}

#Preview {
    SessionSummaryView(record: {
        let record = SessionRecord(
            startedAt: Date(),
            plannedDuration: 1200,
            interval: 300,
            chimeID: ChimeCatalog.default.id,
            endChimeID: ChimeCatalog.default.id,
            ambientID: "rain"
        )
        record.endedAt = Date().addingTimeInterval(1200)
        record.billableSeconds = 1200
        record.endReason = "natural"
        return record
    }())
}
