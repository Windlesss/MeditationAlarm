import SwiftUI

/// 计时运行页。前台时的样子 —— 它的 UI 在后台会被冻结，
/// 但计时与打铃不会停（靠绝对时间戳 + 后台音频会话）。
struct SessionView: View {

    let controller: SessionController
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60)

            VStack(spacing: 10) {
                Text(controller.isPerpetual ? "已冥想" : "剩余")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.inkTertiary)
                    .tracking(2)
                    .textCase(nil)

                Text(controller.remainingText)
                    .font(.system(size: 76, weight: .regular))
                    .foregroundStyle(Palette.ink)
                    .stableDigits()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: controller.remainingText)
            }

            if let progress = controller.progress {
                progressRing(progress)
                    .padding(.top, 36)
            }

            Spacer(minLength: 24)

            Text(summaryLine)
                .font(.system(size: 13))
                .foregroundStyle(Palette.inkTertiary)

            Spacer()

            controls
                .padding(.bottom, 56)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 细分块

    private var summaryLine: String {
        var parts: [String] = []
        if let planned = controller.clock.plannedDuration {
            parts.append(TimeFormatter.minutesString(planned))
        } else {
            parts.append("永久")
        }
        if let interval = controller.clock.interval {
            parts.append("间隔提示 \(Int(interval / 60)) 分钟")
        } else {
            parts.append("无间隔提示")
        }
        return parts.joined(separator: "　·　")
    }

    private func progressRing(_ value: Double) -> some View {
        Circle()
            .trim(from: 0, to: max(0.001, value))
            .stroke(Palette.celadon, style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 208, height: 208)
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button {
                if controller.phase == .paused { controller.resume() } else { controller.pause() }
            } label: {
                Image(systemName: controller.phase == .paused ? "play" : "pause")
                    .font(.system(size: 18, weight: .ultraLight))
                    .foregroundStyle(Palette.inkSub)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)

            Button {
                onEnd()
            } label: {
                Text("结束")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.clay)
                    .tracking(1)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    SessionView(controller: {
        let c = SessionController()
        c.start(.init(
            plannedDuration: 1800, interval: 300,
            chimeID: ChimeCatalog.default.id, endChimeID: ChimeCatalog.default.id,
            ambientID: nil, wasAutoAdjusted: false
        ))
        return c
    }(), onEnd: {})
    .background(Palette.paper)
}
