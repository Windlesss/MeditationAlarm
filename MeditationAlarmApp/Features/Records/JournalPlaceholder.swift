import SwiftUI

/// 记录入口当前为空。预留期展示这句话 + 极简线条插画，**不用 emoji**。
enum JournalPlaceholder {

    struct View: SwiftUI.View {
        var body: some SwiftUI.View {
            VStack(spacing: 28) {
                Rings()
                    .stroke(Palette.hairline, lineWidth: 1)
                    .frame(width: 96, height: 96)

                Text("记录功能即将推出")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.inkSub)
                    .tracking(0.5)

                Text("冥想结束后会在这里汇聚")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.paper)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// 同心细环插画 —— 用 SwiftUI 原生形状，不引入图片资源。
    private struct Rings: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let c = CGPoint(x: rect.midX, y: rect.midY)
            for i in 0..<3 {
                let r = rect.width / 2 * (1 - Double(i) * 0.26)
                path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            path.move(to: c)
            path.addLine(to: CGPoint(x: c.x, y: c.y - rect.width / 2))
            return path
        }
    }
}
