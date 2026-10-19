import SwiftUI

/// 主界面。目标：一眼看懂、一步开始。
///
/// 设计遵循 `DESIGN.md` —— 宣纸底色、超细字重、胶囊选择器、空心圆环按钮。
struct SetupView: View {

    @Bindable var controller: SessionController

    @AppStorage("setup.minutes") private var minutesText: String = "20"
    @AppStorage("setup.perpetual") private var isPerpetual = false
    @AppStorage("setup.interval") private var intervalSeconds: Double = 300
    @AppStorage("setup.chime") private var chimeID: String = ChimeCatalog.default.id
    @AppStorage("setup.ambient") private var ambientID: String = ""
    @AppStorage("setup.chimeVolume") private var chimeVolume: Double = 0.8
    @AppStorage("setup.ambientVolume") private var ambientVolume: Double = 0.5

    /// 时长滚轮的选中档。启动时从上次存储反算（预设值或「自定义」）。
    /// 滚轮只改这里；预设档顺带写回 `minutesText`，自定义档交给输入行。
    @State private var durationIndex: Int = DurationOption.index(
        forMinutes: Int(UserDefaults.standard.string(forKey: "setup.minutes") ?? "20") ?? 20
    )

    @FocusState private var isEditing: Bool

    private var minutes: Int { Int(minutesText) ?? 0 }

    private var plannedDuration: TimeInterval? {
        isPerpetual ? nil : TimeInterval(minutes * 60)
    }

    private var interval: TimeInterval? {
        intervalSeconds > 0 ? intervalSeconds : nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                durationSection
                intervalSection
                if let hint = adjustmentHint {
                    hintBanner(hint)
                }
                SoundSection(controller: controller)
                startButton
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.immediately)
        // numberPad 没有换行键：点任意处收键盘（按钮/选择器自身消费点击，不受影响）
        .dismissKeyboardOnTap()
        // 离开设置页就停掉试听 —— 否则背景音试听会一路循环到计时开始
        .onDisappear {
            Task { @MainActor in AudioEngine.shared.quietDown() }
        }
    }

    // MARK: 时长

    private var durationSection: some View {
        VStack(spacing: 10) {
            Text("冥想时长")
                .font(.system(size: 14))
                .foregroundStyle(Palette.inkTertiary)
                .tracking(1.5)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            if isPerpetual {
                // 永久态：同高度占位，拨动 Toggle 时页面不跳
                Text("永久")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.ink)
                    .frame(height: DurationCapsules.height)
            } else {
                DurationCapsules(
                    options: DurationOption.allCases,
                    selectedIndex: $durationIndex,
                    onSelect: { newIndex in
                        // 预设档直接写回分钟数；进「自定义」清空，交给输入行
                        if let m = DurationOption.allCases[newIndex].minutes {
                            minutesText = "\(m)"
                        } else {
                            minutesText = ""
                        }
                    },
                    customText: $minutesText,
                    customFocus: $isEditing
                )
            }

            Toggle("永久运行", isOn: $isPerpetual)
                .font(.system(size: 14))
                .foregroundStyle(Palette.inkTertiary)
                .tint(Palette.celadon)
                .padding(.top, 2)
        }
    }

    // MARK: 间隔提示

    private var intervalSection: some View {
        VStack(spacing: 14) {
            Text("间隔提示")
                .font(.system(size: 13))
                .foregroundStyle(Palette.inkTertiary)
                .tracking(1.5)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(IntervalOption.allCases) { option in
                        capsule(option)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func capsule(_ option: IntervalOption) -> some View {
        let selected = (option.seconds == interval)
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                intervalSeconds = option.seconds ?? 0
            }
        } label: {
            Text(option.label)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Palette.ink : Palette.inkSub)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(selected ? Palette.celadonBg : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 联动提示

    private struct Hint { let from: TimeInterval; let to: TimeInterval }

    private var adjustmentHint: Hint? {
        guard !isPerpetual, let i = interval, let p = plannedDuration else { return nil }
        if p < i { return Hint(from: p, to: i * 5) }
        return nil
    }

    private func hintBanner(_ hint: Hint) -> some View {
        Text("时长 \(Int(hint.from / 60)) 分钟短于间隔，开始时自动置为 \(Int(hint.to / 60)) 分钟")
            .font(.system(size: 12))
            .foregroundStyle(Palette.ochre)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Palette.celadonBg.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 开始

    private var startButton: some View {
        Button {
            let resolved = DurationPolicy.resolve(
                plannedDuration: plannedDuration,
                interval: interval
            )
            controller.start(.init(
                plannedDuration: resolved.plannedDuration,
                interval: interval,
                chimeID: ChimeCatalog.resolve(chimeID).id,
                endChimeID: ChimeCatalog.resolve(chimeID).id,
                ambientID: ambientID.isEmpty ? nil : ambientID,
                chimeVolume: chimeVolume,
                ambientVolume: ambientVolume,
                wasAutoAdjusted: resolved.wasAdjusted
            ))
        } label: {
            Text("开始")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Palette.ink)
                .tracking(3)
                .frame(width: 132, height: 132)
                .overlay {
                    Circle()
                        .stroke(Palette.hairline, lineWidth: 2)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isPerpetual && minutes <= 0)
        .opacity((!isPerpetual && minutes <= 0) ? 0.4 : 1)
    }
}

// MARK: - 音色选择 + 试听

/// 试听规则（用户确认）：
/// - 选提示音 / 选背景音 → **立刻播一下**，打断当前正在试听的声音
/// - 拖提示音音量 → 拖动中实时改音量，**放手时再播一次**
/// - 拖背景音音量 → 正在试听的就是这个背景音就**只改音量**；
///   正在放的是别的声音就**切换成播放这个背景音**
private struct SoundSection: View {

    @Bindable var controller: SessionController

    @AppStorage("setup.chime") private var chimeID: String = ChimeCatalog.default.id
    @AppStorage("setup.ambient") private var ambientID: String = ""
    @AppStorage("setup.chimeVolume") private var chimeVolume: Double = 0.8
    @AppStorage("setup.ambientVolume") private var ambientVolume: Double = 0.5

    /// 音量条防抖。Slider 拖动时每秒触发几十次 onChange，
    /// 每次都重新播放会变成一团持续的嗡嗡声；80ms 内只认最后一次。
    @State private var volumeTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            Divider().background(Palette.hairline)

            row("提示音") {
                Picker("", selection: $chimeID) {
                    ForEach(ChimeCatalog.all) { Text($0.name).tag($0.id) }
                }
                .tint(Palette.inkSub)
                .labelsHidden()
                .onChange(of: chimeID) { _, new in
                    Task { @MainActor in
                        AudioEngine.shared.previewChime(ChimeCatalog.resolve(new), volume: chimeVolume)
                    }
                }
            }

            row("背景音") {
                Picker("", selection: $ambientID) {
                    Text("无").tag("")
                    ForEach(AmbientCatalog.all) { Text($0.name).tag($0.id) }
                }
                .tint(Palette.inkSub)
                .labelsHidden()
                .onChange(of: ambientID) { _, new in
                    Task { @MainActor in
                        if new.isEmpty {
                            AudioEngine.shared.quietDown()
                        } else {
                            AudioEngine.shared.previewAmbient(
                                AmbientCatalog.resolve(new) ?? AmbientCatalog.off,
                                volume: ambientVolume
                            )
                        }
                    }
                }
            }

            row("提示音音量") {
                Slider(value: $chimeVolume, in: 0...1) { editing in
                    // 放手时播一次，让用户听清新音量下的音色
                    if !editing {
                        Task { @MainActor in
                            AudioEngine.shared.previewChime(
                                ChimeCatalog.resolve(chimeID), volume: chimeVolume
                            )
                        }
                    }
                }
                .tint(Palette.celadon)
                .frame(width: 150)
                .onChange(of: chimeVolume) { _, new in
                    debounce { AudioEngine.shared.adjustChimeVolume(volume: new) }
                }
            }

            row("背景音音量") {
                Slider(value: $ambientVolume, in: 0...1) { _ in }
                    .tint(Palette.celadon)
                    .frame(width: 150)
                    .onChange(of: ambientVolume) { _, new in
                        // 语义交给引擎：正在放这个背景音就只改音量，
                        // 放的是别的就切换过来
                        debounce {
                            AudioEngine.shared.adjustAmbientVolume(id: ambientID, volume: new)
                        }
                    }
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Palette.inkSub)
            Spacer()
            content()
        }
    }

    private func debounce(_ action: @escaping @MainActor () -> Void) {
        volumeTask?.cancel()
        volumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

// MARK: - 键盘收起

extension View {
    /// 点任意处收起键盘。numberPad 没有换行键，这是主要收起手段；
    /// 键盘工具栏「完成」是兜底。按钮 / 选择器 / 滑杆自身消费点击，不受影响。
    func dismissKeyboardOnTap() -> some View {
        self.onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
    }
}

#Preview {
    SetupView(controller: SessionController())
        .background(Palette.paper)
}
