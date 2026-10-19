import ActivityKit
import SwiftUI
import WidgetKit

/// 实时活动的视图：**锁屏**（全机型可见，优先级最高）+ 灵动岛紧凑/展开。
///
/// ⚠️ 这里是**纯黑底**，不能用 App 的宣纸浅色。走 `Palette` 的深色变体。
struct MeditationActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeditationActivityAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    expandedStatus(context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        TimeText(state: context.state)
                            .font(.system(size: 26, weight: .thin))
                        Text(context.state.phase == .paused ? "暂停" : (context.state.plannedDuration == nil ? "已冥想" : "剩余"))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.islandSub)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        ControlButton(title: "暂停", systemImage: "pause", command: .togglePause)
                        ControlButton(title: "结束", systemImage: "stop.fill", command: .end)
                    }
                    .frame(height: 36)
                }
            } compactLeading: {
                Image(systemName: context.state.phase == .paused ? "pause" : "circle.badge.checkmark")
                    .font(.system(size: 12, weight: .ultraLight))
                    .foregroundStyle(Palette.celadonOnDark)
            } compactTrailing: {
                TimeText(state: context.state)
                    .font(.system(size: 13, weight: .light))
            } minimal: {
                Image(systemName: "circle.badge.checkmark")
                    .font(.system(size: 12, weight: .ultraLight))
                    .foregroundStyle(Palette.celadonOnDark)
            }
        }
    }

    @ViewBuilder
    private func expandedStatus(_ context: ActivityViewContext<MeditationActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("冥想中")
                .font(.system(size: 12))
                .foregroundStyle(Palette.islandSub)
            Text(context.attributes.summary)
                .font(.system(size: 11))
                .foregroundStyle(Palette.islandSub.opacity(0.8))
            if context.state.phase == .paused {
                Text("已暂停")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.celadonOnDark)
            }
        }
    }
}

// MARK: - 倒计时文本

/// 三种情况，优先级从上到下：
/// 1. 有终点且在运行 → `Text(style: .timer)`，**系统逐秒刷新**，零预算消耗
/// 2. 暂停 → 静态文本（不会再变）
/// 3. 永久运行 → 已冥想时长的快照（随 App 推送更新）
private struct TimeText: View {
    let state: MeditationActivityAttributes.ContentState

    var body: some View {
        Group {
            if let target = state.targetEnd {
                Text(target, style: .timer)
                    .monospacedDigit()
            } else if state.phase == .paused, let text = state.staticRemainingText {
                Text(text).monospacedDigit()
            } else {
                Text(TimeFormatter.string(state.snapshotElapsed)).monospacedDigit()
            }
        }
        .foregroundStyle(Palette.islandText)
    }
}

// MARK: - 按钮

private struct ControlButton: View {
    let title: String
    let systemImage: String
    let command: ControlBus.Command

    var body: some View {
        Button(intent: MeditationControlIntent(command: command)) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .ultraLight))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(Palette.islandText)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Palette.islandText.opacity(0.14))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 锁屏视图

private struct LockScreenView: View {
    let context: ActivityViewContext<MeditationActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .trim(from: 0, to: 0.999)
                .stroke(Palette.celadonOnDark.opacity(0.45), lineWidth: 1.5)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: context.state.phase == .paused ? "pause" : "circle.badge.checkmark")
                        .font(.system(size: 13, weight: .ultraLight))
                        .foregroundStyle(Palette.celadonOnDark)
                }

            VStack(alignment: .leading, spacing: 1) {
                TimeText(state: context.state)
                    .font(.system(size: 22, weight: .thin))
                Text(context.attributes.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.islandSub)
            }

            Spacer()

            ControlButton(title: "结束", systemImage: "stop.fill", command: .end)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .activityBackgroundTint(Palette.islandBg)
        .activitySystemActionForegroundColor(Palette.islandText)
    }
}
