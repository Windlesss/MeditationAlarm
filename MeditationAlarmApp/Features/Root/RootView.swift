import SwiftUI

/// App 根视图。主界面无导航栏标题栏，只在右上角留一个记录入口。
struct RootView: View {

    @Bindable var controller: SessionController

    var body: some View {
        NavigationStack {
            content
                .background(Palette.paper)
                .toolbar {
                    // 记录入口：次要功能位，单图标不破坏主界面的「空」
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            JournalPlaceholder.View()
                        } label: {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 20, weight: .ultraLight))
                                .foregroundStyle(Palette.inkTertiary)
                        }
                    }
                }
        }
        .preferredColorScheme(.light)   // 产品定位就是浅色，不做深色模式
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle, .ended:
            SetupView(controller: controller)
        case .running, .paused:
            SessionView(controller: controller) {
                _ = controller.end(reason: .manual)
            }
        }
    }
}

#Preview {
    RootView(controller: SessionController())
}
