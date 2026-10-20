import SwiftUI

/// App 根视图。主界面无导航栏标题栏，只在右上角留一个记录入口。
struct RootView: View {

    @Bindable var controller: SessionController

    /// 记录服务单例。@Observable，直接访问即被观察跟踪。
    private let journal = SessionJournal.shared

    /// 二级路由。目前只有记录页；调试后门可直接 push 它。
    @State private var path = NavigationPath()

    /// 健康小结页展示的记录（第三阶段 v3a）。记录闭合且本场有健康数据时轻推一格。
    @State private var summaryRecord: SessionRecord?

    private enum RecordsRoute: Hashable {
        case records
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background(Palette.paper)
                .toolbar {
                    // 记录入口：次要功能位，单图标不破坏主界面的「空」
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: RecordsRoute.records) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 20, weight: .ultraLight))
                                .foregroundStyle(Palette.inkTertiary)
                        }
                    }
                }
                .navigationDestination(for: RecordsRoute.self) { route in
                    switch route {
                    case .records: RecordsView()
                    }
                }
        }
        .preferredColorScheme(.light)   // 产品定位就是浅色，不做深色模式
        .onAppear {
            // 调试后门：`defaults write <bundle-id> debug.openRecords -bool true`
            // 后启动，可直接进记录页（模拟器点不到右上角图标）。
            if UserDefaults.standard.bool(forKey: "debug.openRecords") {
                path.append(RecordsRoute.records)
            }
            // 调试后门：直接展示最新记录的小结页（模拟器验证健康 UI 用）。
            if UserDefaults.standard.bool(forKey: "debug.openSummary"),
               let record = journal.latestClosedRecord() {
                summaryRecord = record
            }
        }
        // 结束二次确认（FR-2.3）。App 内结束按钮与 LA「结束 → 打开 App」共用。
        .alert("结束本次冥想？", isPresented: endConfirmAlert) {
            Button("结束", role: .destructive) { controller.confirmEnd() }
            Button("继续冥想", role: .cancel) { controller.cancelEnd() }
        } message: {
            Text("本次已冥想 \(controller.elapsedText)，结束后将播放收尾音")
        }
        // 短会话记录确认（用户 2026-10-20 决策）。默认「记录」。
        .alert("记录这次冥想？", isPresented: recordConfirmAlert) {
            Button("记录") { journal.commitPending() }
            Button("不记录", role: .cancel) { journal.discardPending() }
        } message: {
            Text(pendingRecordMessage)
        }
        // 健康小结页（第三阶段 v3a）：记录闭合且本场有健康数据时呈现。
        // 无数据不呈现 —— 不留空页（FR-10.5 的 UI 侧体现）。
        .onChange(of: journal.lastClosedRecordID) { _, newID in
            guard let newID else { return }
            if let record = journal.record(id: newID), !record.vitals.isEmpty {
                summaryRecord = record
            }
            journal.clearLastClosed()
        }
        .sheet(item: $summaryRecord) { record in
            SessionSummaryView(record: record)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle, .ended:
            SetupView(controller: controller)
        case .running, .paused:
            // 结束按钮只挂起确认，不直接结束（FR-2.3 + LA 链路统一入口）
            SessionView(controller: controller) {
                controller.requestEnd()
            }
        }
    }

    // MARK: alert 绑定

    private var endConfirmAlert: Binding<Bool> {
        Binding(
            get: { controller.pendingEndConfirmation },
            set: { if !$0 { controller.cancelEnd() } }
        )
    }

    private var recordConfirmAlert: Binding<Bool> {
        Binding(
            get: { journal.pendingConfirmation != nil },
            set: { if !$0 { journal.discardPending() } }
        )
    }

    private var pendingRecordMessage: String {
        guard let pending = journal.pendingConfirmation else { return "" }
        let seconds = Int(pending.seconds)
        let text = seconds >= 60 ? "\(seconds / 60) 分 \(seconds % 60) 秒" : "\(seconds) 秒"
        return "本次时长 \(text)，不足 \(Self.thresholdText)，仍要记录吗？"
    }

    /// 阈值文案：与 SessionJournal.recordThreshold 联动（DEBUG 60s / 正式 180s）。
    private static var thresholdText: String {
        let minutes = Int(SessionJournal.recordThreshold) / 60
        return "\(max(1, minutes)) 分钟"
    }
}

#Preview {
    RootView(controller: SessionController())
}
