import SwiftUI
import Charts

// 注意：不 import MeditationCore —— 它的源码直编进本 target（双 target 直编方案），
// 同模块符号直接可见。

/// 一条记录的健康区块（心率 / HRV），小结页与详情页共用。
///
/// FR-10.5：某指标无有效数据时**整块（含标题）不渲染** —— 未授权、无手表、
/// 全零三种情况同一表现，不留空板块、不留「暂无数据」。
struct RecordVitalsSections: View {
    let record: SessionRecord

    private var book: VitalsBook {
        var book = VitalsBook()
        book.ingest(record.vitals.map(\.asReading))
        return book
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            section(kind: .heartRate)
            section(kind: .hrvSDNN)
        }
    }

    private func section(kind: VitalKind) -> some View {
        VitalSectionView(
            kind: kind,
            presentation: book.presentation(
                of: kind,
                sessionStart: record.startedAt,
                sessionEnd: record.endedAt
            )
        )
    }
}

/// 单个指标区块。按 `VitalPresentation` 三态渲染：
/// - `.hidden`：整块不渲染；
/// - `.single`：只显示单值（不显示最高/最低/平均 —— 对单值无意义，也不显示数量）；
/// - `.series`：画图 + 每个点标数值 + 底部「最高 · 最低 · 平均」摘要。心率连线 + 点；
///   HRV 只画点 + 细竖线 —— 稀疏点之间连线等于凭空编造趋势
///   （REQUIREMENTS D4.2 诚实呈现原则）。
///
/// 呈现约定（用户 2026-10-20 决策）：不显示「N 个采样点」之类的计数，只标点位与数据。
struct VitalSectionView: View {
    let kind: VitalKind
    let presentation: VitalPresentation

    var body: some View {
        switch presentation {
        case .hidden:
            EmptyView()

        case .single(let value):
            VStack(alignment: .leading, spacing: 10) {
                header
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(formatted(value))
                        .font(.system(size: 26, weight: .thin))
                        .foregroundStyle(Palette.ink)
                        .stableDigits()
                    Text(kind.unitLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.inkTertiary)
                    Spacer()
                }
            }

        case .series(let points):
            VStack(alignment: .leading, spacing: 10) {
                header
                chart(points)
                summaryLine(points)
                Text("横轴 = 相对冥想开始的分钟数")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }

    private var header: some View {
        Text(kind.displayName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.ink)
    }

    /// 每个点用 `annotation` 标出数值（方案 A：数值标在点上），
    /// 心率取整、HRV 保留一位小数，与摘要口径一致。
    ///
    /// **密集抽稀**：点全部保留（曲线与点画全），但当相邻点的横轴距离太近时，
    /// 只给其中一个标数值（贪心：从左到右，与上一个已标点的间距 < 阈值就跳过）。
    /// 被跳过的点数值由「最高 / 最低 / 平均」摘要行兜底，信息不丢。
    ///
    /// 抽稀阈值按图表实际宽度归一化（横轴 = 相对冥想开始的分钟数，图表总宽固定，
    /// 会话越长每秒钟对应的像素越少），用 GeometryReader 拿真实宽度反推。
    private func chart(_ points: [VitalPoint]) -> some View {
        GeometryReader { geo in
            let annotated = annotateIndices(points, chartWidth: geo.size.width)
            Chart(points, id: \.offsetSeconds) { point in
                let x = point.offsetSeconds / 60
                if kind == .heartRate {
                    LineMark(
                        x: .value("分钟", x),
                        y: .value(kind.unitLabel, point.value)
                    )
                    .foregroundStyle(Palette.celadon)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    PointMark(
                        x: .value("分钟", x),
                        y: .value(kind.unitLabel, point.value)
                    )
                    .foregroundStyle(Palette.celadon)
                    .symbolSize(22)
                    .annotation(position: .top, spacing: 3) {
                        if annotated.contains(point.offsetSeconds) {
                            valueLabel(point)
                        }
                    }
                } else {
                    // HRV：点 + 细竖线，不连线
                    RuleMark(x: .value("分钟", x))
                        .foregroundStyle(Palette.celadon.opacity(0.45))
                    PointMark(
                        x: .value("分钟", x),
                        y: .value(kind.unitLabel, point.value)
                    )
                    .foregroundStyle(Palette.celadon)
                    .symbolSize(26)
                    .annotation(position: .top, spacing: 3) {
                        if annotated.contains(point.offsetSeconds) {
                            valueLabel(point)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
        }
        .frame(height: 96)
    }

    private func valueLabel(_ point: VitalPoint) -> some View {
        Text(formatted(point.value))
            .font(.system(size: 11))
            .foregroundStyle(Palette.inkSub)
    }

    /// 贪心抽稀：返回应标数值的点的 `offsetSeconds` 集合。
    /// 阈值随图表实际宽度归一化 —— 标签文字约 26pt 宽，需要预留 26pt 横轴间距
    /// （另加 6pt 缓冲），换算成秒数就是「每秒占的像素」的倒数。
    private func annotateIndices(_ points: [VitalPoint], chartWidth: CGFloat) -> Set<TimeInterval> {
        guard let first = points.first, let last = points.last else { return [] }
        let span = last.offsetSeconds - first.offsetSeconds
        guard span > 0, chartWidth > 0 else { return Set(points.map(\.offsetSeconds)) }

        // 标签所需最小像素间距 → 折算成秒
        let labelPt: CGFloat = 32
        let minGapSeconds = span * TimeInterval(labelPt / chartWidth)

        var result = Set<TimeInterval>()
        var lastAnnotated: TimeInterval?
        for point in points {
            if let lastAnnotated, point.offsetSeconds - lastAnnotated < minGapSeconds {
                continue
            }
            result.insert(point.offsetSeconds)
            lastAnnotated = point.offsetSeconds
        }
        return result
    }

    /// 「最高 · 最低 · 平均」摘要行。平均值按与点标一致的精度四舍五入。
    private func summaryLine(_ points: [VitalPoint]) -> some View {
        let values = points.map(\.value)
        let maxV = values.max() ?? 0
        let minV = values.min() ?? 0
        let avgV = values.reduce(0, +) / Double(values.count)

        func seg(_ label: String, _ v: Double) -> Text {
            Text("\(label) \(formatted(v))")
                .font(.system(size: 12))
                .foregroundStyle(Palette.inkSub)
        }

        return HStack(spacing: 0) {
            seg("最高", maxV)
            Text(" · ").font(.system(size: 12)).foregroundStyle(Palette.inkTertiary)
            seg("最低", minV)
            Text(" · ").font(.system(size: 12)).foregroundStyle(Palette.inkTertiary)
            seg("平均", avgV)
        }
    }

    /// 心率取整、HRV 保留一位小数。
    private func formatted(_ value: Double) -> String {
        kind == .heartRate
            ? "\(Int(value.rounded()))"
            : String(format: "%.1f", value)
    }
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 26) {
            VitalSectionView(
                kind: .heartRate,
                presentation: .series([
                    VitalPoint(offsetSeconds: 120, value: 64),
                    VitalPoint(offsetSeconds: 540, value: 60),
                    VitalPoint(offsetSeconds: 960, value: 59),
                    VitalPoint(offsetSeconds: 1380, value: 58),
                ])
            )
            VitalSectionView(
                kind: .hrvSDNN,
                presentation: .series([
                    VitalPoint(offsetSeconds: 480, value: 42.3),
                    VitalPoint(offsetSeconds: 1200, value: 38.7),
                ])
            )
            VitalSectionView(
                kind: .heartRate,
                presentation: .single(value: 62)
            )
        }
        .padding(24)
    }
    .background(Palette.paper)
}
