import SwiftUI

// MARK: - 时长档位

/// 冥想时长的档位表。形态演进（均见 DESIGN.md 五.1）：
/// 大数字自由输入 → 垂直滚轮 → 横向滚轮 → 两行 5+4 胶囊 →
/// **一行横滑胶囊**（2026-10-19 用户最终决策：两行没有滑动感，不适应）。
///
/// `custom` 选中时，具体分钟数由胶囊排下方淡出的输入行编辑。
enum DurationOption: Identifiable, Hashable, CaseIterable {

    case minutes(Int)
    case hours(Int)
    case custom

    static var allCases: [DurationOption] {
        [
            .minutes(5), .minutes(10), .minutes(20), .minutes(30), .minutes(45),
            .hours(1), .hours(2), .hours(5),
            .custom
        ]
    }

    var id: Self { self }

    /// 胶囊标签刻意用「分 / 时」缩写（间隔提示是「秒 / 分钟」全称）——
    /// 第一行要在一屏内并排 5 个，全称放不下。
    var label: String {
        switch self {
        case .minutes(let m): return "\(m) 分"
        case .hours(let h): return "\(h) 小时"
        case .custom: return "自定义"
        }
    }

    /// 预设档位的分钟数；`custom` 为 nil（由输入行决定）。
    var minutes: Int? {
        switch self {
        case .minutes(let m): return m
        case .hours(let h): return h * 60
        case .custom: return nil
        }
    }

    /// 「自定义」在档位表里的序号。
    static let customIndex: Int = allCases.count - 1

    /// 分钟数 → 档位序号。不在预设里一律落「自定义」。
    static func index(forMinutes m: Int) -> Int {
        allCases.firstIndex(where: { $0.minutes == m }) ?? customIndex
    }
}

// MARK: - 两行胶囊选择器

/// 一行横滑胶囊时长选择器（2026-10-19 用户最终决策）：
/// - 交互同间隔提示：横向 ScrollView 可滑 + 点选即中
/// - 优化点：**选中项字号 13 → 18pt 并增高**，配青瓷底，静态界面里自己跳出来
/// - 9 个档位一屏放不下（约 500pt > 311pt），右缘截断即暗示可滑；选中项自动滚到居中
/// - 「自定义」选中时，胶囊排下方淡出一行分钟输入（数字键盘 + 工具栏「完成」）
struct DurationCapsules: View {

    let options: [DurationOption]
    @Binding var selectedIndex: Int
    /// 选中落定后回调（父视图据此把预设分钟数写回 `setup.minutes`）。
    var onSelect: (Int) -> Void = { _ in }
    /// 「自定义」的分钟输入。
    var customText: Binding<String>
    var customFocus: FocusState<Bool>.Binding

    /// 单行胶囊占位高度（「永久」态同高占位，拨 Toggle 时页面不跳）。
    static let height: CGFloat = 40

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            capsule(option, index: index)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
                // 选中项可能启动时就在屏外（如上次存的是「1 时」）——进场滚到居中；
                // 点选后也居中，跟手滑到一半松手不抢控制权（selectedIndex 只在点击时变）。
                .onAppear { proxy.scrollTo(selectedIndex, anchor: .center) }
                .onChange(of: selectedIndex) { _, new in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }

            if selectedIndex == DurationOption.customIndex {
                customInputRow
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
    }

    // MARK: 输入行

    private var customInputRow: some View {
        HStack(spacing: 6) {
            TextField("输入分钟", text: customText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 22))
                .foregroundStyle(Palette.ink)
                .frame(width: 84)
                .stableDigits()
                .focused(customFocus)
                .tint(Palette.celadon)
                // numberPad 没有换行键，工具栏「完成」是标准解法
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成") { customFocus.wrappedValue = false }
                    }
                }
            Text("分钟")
                .font(.system(size: 14))
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    // MARK: 胶囊

    private func capsule(_ option: DurationOption, index: Int) -> some View {
        let selected = index == selectedIndex
        return Button {
            // 守卫：重复点「自定义」不能清空已输入的分钟数
            if index != selectedIndex {
                withAnimation(.easeOut(duration: 0.18)) {
                    selectedIndex = index
                    onSelect(index)
                }
            }
            // 落到「自定义」直接唤起键盘，省一次点击
            if index == DurationOption.customIndex {
                customFocus.wrappedValue = true
            }
        } label: {
            Text(option.label)
                .font(.system(size: selected ? 18 : 13))
                .foregroundStyle(selected ? Palette.ink : Palette.inkSub)
                .padding(.horizontal, selected ? 14 : 12)
                .padding(.vertical, selected ? 8 : 7)
                .background(selected ? Palette.celadonBg : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
