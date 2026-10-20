import SwiftData
import SwiftUI

/// 冥想记录页（第二阶段，用户 2026-10-20 落地）。
///
/// 结构：统计头部 → 日历热力图（月视图）→ 按天分组的会话列表。
/// 删除走左滑 + 二次确认；详情为底部卡片。
/// 设计遵循 DESIGN.md：宣纸底、青瓷色阶、超细字重、无卡片层叠。
struct RecordsView: View {

    // 只列已闭合、未作废的记录。open 记录（App 被杀留下的未结束会话）与
    // 作废记录（短会话被用户放弃）都不是记录页的内容。
    @Query(
        filter: #Predicate<SessionRecord> { $0.endedAt != nil && !$0.isDiscarded },
        sort: \SessionRecord.startedAt,
        order: .reverse
    )
    private var records: [SessionRecord]

    @Environment(\.modelContext) private var modelContext

    /// 日历当前展示的月份（任意一天即可定位到该月）。
    @State private var month: Date = Date()
    /// 详情卡片展示的记录。
    @State private var detail: SessionRecord?
    /// 等待确认删除的记录。
    @State private var pendingDelete: SessionRecord?

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                if records.isEmpty {
                    emptyState
                } else {
                    statsHeader
                    calendarSection
                    listSection
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .background(Palette.paper)
        .navigationTitle("记录")
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除这条记录？", isPresented: deleteAlert,
               presenting: pendingDelete) { record in
            Button("删除", role: .destructive) {
                modelContext.delete(record)
                try? modelContext.save()
            }
            Button("取消", role: .cancel) {}
        } message: { record in
            Text("\(record.startedAt, style: .date) \(record.startedAt, style: .time) · \(Self.durationText(record.billableSeconds))")
        }
        .sheet(item: $detail) { record in
            RecordDetailSheet(record: record)
                .presentationDetents([.medium])
        }
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 60)
            // 同心细环插画 —— 与预留期占位页同一语言
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(Palette.hairline, lineWidth: 1)
                        .frame(width: CGFloat(96 - i * 26), height: CGFloat(96 - i * 26))
                }
            }
            .frame(width: 96, height: 96)

            Text("还没有记录")
                .font(.system(size: 15))
                .foregroundStyle(Palette.inkSub)
                .tracking(0.5)
            Text("完成的冥想会汇聚到这里")
                .font(.system(size: 12))
                .foregroundStyle(Palette.inkTertiary)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 统计头部

    private var statsHeader: some View {
        HStack(spacing: 0) {
            stat(value: "\(records.count)", label: "次数")
            statDivider
            stat(value: Self.durationText(totalSeconds), label: "累计时长")
            statDivider
            stat(value: "\(streakDays)", label: "连续天数")
        }
        .padding(.vertical, 18)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 24, weight: .thin))
                .foregroundStyle(Palette.ink)
                .stableDigits()
                // 三列等宽，长文案（如「3 小时 53 分」）不允许折行，按比例缩小
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Palette.inkTertiary)
                .tracking(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: 0.5, height: 28)
    }

    // MARK: 日历热力图

    private var calendarSection: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    month = calendar.date(byAdding: .month, value: -1, to: month) ?? month
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .ultraLight))
                        .foregroundStyle(Palette.inkTertiary)
                        .frame(width: 32, height: 32)
                }
                Spacer()
                Text(monthTitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.inkSub)
                    .tracking(1)
                Spacer()
                Button {
                    month = calendar.date(byAdding: .month, value: 1, to: month) ?? month
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .ultraLight))
                        .foregroundStyle(Palette.inkTertiary)
                        .frame(width: 32, height: 32)
                }
            }

            // 星期表头
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkTertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            // 日期网格
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(monthDays, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let seconds = seconds(on: day)
        let isToday = calendar.isDate(day, inSameDayAs: Date())
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        return VStack(spacing: 3) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 10))
                .foregroundStyle(inMonth ? Palette.inkTertiary : Palette.inkTertiary.opacity(0.3))
            RoundedRectangle(cornerRadius: 4)
                .fill(heatColor(seconds))
                .frame(height: 22)
                .overlay {
                    if isToday {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Palette.celadon, lineWidth: 1)
                    }
                }
        }
        .opacity(inMonth ? 1 : 0.35)
    }

    /// 当日累计时长 → 青瓷色阶四档（0 = 空心）。
    private func heatColor(_ seconds: TimeInterval) -> Color {
        switch seconds {
        case 0: return Palette.hairline.opacity(0.5)
        case ..<900: return Palette.celadonBg
        case ..<1800: return Palette.celadon.opacity(0.35)
        case ..<2700: return Palette.celadon.opacity(0.6)
        default: return Palette.celadon.opacity(0.85)
        }
    }

    // MARK: 会话列表

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groupedRecords, id: \.day) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(dayTitle(group.day))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.inkTertiary)
                        .tracking(1)
                        .padding(.bottom, 10)

                    ForEach(group.items) { record in
                        row(record)
                        Divider().background(Palette.hairline)
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    private func row(_ record: SessionRecord) -> some View {
        Button {
            detail = record
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.startedAt, style: .time)
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.ink)
                        .stableDigits()
                    Text(subtitle(record))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkTertiary)
                }
                Spacer()
                Text(Self.durationText(record.billableSeconds))
                    .font(.system(size: 15, weight: .thin))
                    .foregroundStyle(Palette.inkSub)
                    .stableDigits()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = record
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func subtitle(_ record: SessionRecord) -> String {
        var parts: [String] = []
        parts.append(record.endReason == "natural" ? "自然结束" : "手动结束")
        if let planned = record.plannedDuration {
            parts.append("计划 \(Self.durationText(planned))")
        } else {
            parts.append("永久")
        }
        if record.wasAutoAdjusted { parts.append("已自动调整") }
        return parts.joined(separator: " · ")
    }

    // MARK: 派生数据

    private var totalSeconds: TimeInterval {
        records.reduce(0) { $0 + $1.billableSeconds }
    }

    /// 连续天数（用户 2026-10-20 口径：当天有任意时长即算 1 天）。
    /// 从今天往回数，今天没有记录即断（严格口径，不做「今天还没做」的宽限）。
    private var streakDays: Int {
        let daysWithRecords = Set(records.map { calendar.startOfDay(for: $0.startedAt) })
        var streak = 0
        var cursor = calendar.startOfDay(for: Date())
        while daysWithRecords.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    private struct DayGroup {
        let day: Date
        let items: [SessionRecord]
    }

    private var groupedRecords: [DayGroup] {
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { DayGroup(day: $0, items: grouped[$0]!) }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月"
        return formatter.string(from: month)
    }

    private var weekdaySymbols: [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.shortWeekdaySymbols.map { String($0) }
    }

    /// 当前月份的网格日期（含上下月补位，周一开头）。
    private var monthDays: [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: monthInterval.start)
        else { return [] }
        var days: [Date] = []
        var cursor = firstWeek.start
        // 6 行 × 7 列足够覆盖任何月份
        while days.count < 42 {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    private func seconds(on day: Date) -> TimeInterval {
        records
            .filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
            .reduce(0) { $0 + $1.billableSeconds }
    }

    private func dayTitle(_ day: Date) -> String {
        if calendar.isDate(day, inSameDayAs: Date()) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()),
           calendar.isDate(day, inSameDayAs: yesterday) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 EEE"
        return formatter.string(from: day)
    }

    private var deleteAlert: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    /// 时长文案：满 1 小时显示「X 小时 Y 分」，满 1 分钟「X 分」，否则「X 秒」。
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return "\(total / 3600) 小时 \(total % 3600 / 60) 分"
        }
        if total >= 60 {
            return "\(total / 60) 分"
        }
        return "\(max(0, total)) 秒"
    }
}

// MARK: - 详情

private struct RecordDetailSheet: View {
    let record: SessionRecord

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    detailRow("开始", record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    detailRow("结束", record.endedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    detailRow("实际时长", RecordsView.durationText(record.billableSeconds))
                    detailRow("计划时长", record.plannedDuration.map { RecordsView.durationText($0) } ?? "永久")
                    detailRow("结束方式", record.endReason == "natural" ? "自然结束" : "手动结束")
                    if let interval = record.interval, interval > 0 {
                        detailRow("间隔提示", IntervalOption.fixed(interval).label)
                    } else {
                        detailRow("间隔提示", "无")
                    }
                    detailRow("提示音", ChimeCatalog.resolve(record.chimeID).name)
                    detailRow("背景音", record.ambientID.flatMap { AmbientCatalog.resolve($0)?.name } ?? "无")
                    if record.wasAutoAdjusted {
                        detailRow("自动调整", "时长不足间隔，已扩展")
                    }
                    // 健康数据（第三阶段 v3a）：无样本时整组不渲染
                    if !record.vitals.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Divider().background(Palette.hairline).padding(.vertical, 16)
                            RecordVitalsSections(record: record)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(Palette.paper)
            .navigationTitle("冥想详情")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.inkTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(Palette.inkSub)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Divider().background(Palette.hairline)
        }
    }
}
