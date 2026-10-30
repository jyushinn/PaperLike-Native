import PaperlikeCore
import SwiftUI

public struct QuickPanelView: View {
    @ObservedObject var model: AppModel
    private let showsTouchPreview: Bool
    private let showsTouchAuthorizationPreview: Bool
    @State private var showingFrontLightPresetNamePrompt = false
    @State private var newFrontLightPresetName = ""

    public init(
        model: AppModel,
        showsTouchPreview: Bool = false,
        showsTouchAuthorizationPreview: Bool = false
    ) {
        self.model = model
        self.showsTouchPreview = showsTouchPreview
        self.showsTouchAuthorizationPreview = showsTouchAuthorizationPreview
    }

    public var body: some View {
        VStack(spacing: 0) {
            connectionHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if model.allControlsPaused {
                        Button("恢复自动控制") { model.resumeImportedConfiguration() }
                            .frame(maxWidth: .infinity)
                    }
                    if !model.isConnected {
                        ContentUnavailableView("控制未连接", systemImage: "cable.connector", description: Text("等待控制串口，视频与触控连接单独检测。"))
                        Button("重新连接") { model.reconnect() }
                            .frame(maxWidth: .infinity)
                    } else {
                    panelSection("场景") {
                        HStack {
                            Button("应用我的场景") {
                                if let preset = model.presets.first { model.applyPreset(preset) }
                            }
                            .disabled(model.presets.isEmpty)
                            Spacer()
                            Button("更新我的场景", systemImage: "square.and.arrow.down") {
                                model.saveCurrentPreset()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(!model.isConnected || model.isCommandRunning)

                    panelSection("显示") {
                        displayControls
                    }
                    if model.frontLightAvailable {

                        panelSection("前光") {
                            frontLightControls
                        }
                    }
                    }

                    panelSection("自动化") {
                        automationControls
                    }
                    if showsTouchPreview || showsTouchAuthorizationPreview || model.touchIsTouchDeviceConnected || model.touchMappingActive || model.canResumeTouch {
                        panelSection("触控") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(touchPreviewStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    if showsTouchPreview {
                                        Button("暂停触控", systemImage: "pause.circle") { }
                                            .disabled(true)
                                            .frame(maxWidth: .infinity)
                                    } else if model.touchMappingActive {
                                        Button("暂停触控", systemImage: "pause.circle") { model.pauseTouch() }
                                            .frame(maxWidth: .infinity)
                                    } else if showsTouchAuthorizationPreview {
                                        Button("授权触控", systemImage: "hand.tap") { }
                                            .frame(maxWidth: .infinity)
                                        Button("重新检查授权", systemImage: "arrow.clockwise") { }
                                            .frame(maxWidth: .infinity)
                                    } else if !model.touchIsAccessibilityTrusted {
                                        Button("授权触控", systemImage: "hand.tap") {
                                            model.requestTouchAccessibility()
                                        }
                                        .frame(maxWidth: .infinity)
                                        Button("重新检查授权", systemImage: "arrow.clockwise") {
                                            model.refreshTouchPermission()
                                        }
                                        .frame(maxWidth: .infinity)
                                    } else if model.canResumeTouch {
                                        Button("继续触控", systemImage: "play.circle") { model.resumeTouch() }
                                            .frame(maxWidth: .infinity)
                                    } else {
                                        Button("触控设置", systemImage: "slider.horizontal.3") {
                                            model.settingsDestination = .touch
                                            model.showSettings()
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .toggleStyle(.switch)
        }
            .frame(width: 360, height: panelHeight)
        .alert(
            "PaperLike Native",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好") { model.errorMessage = nil }
            if model.configurationRecoveryNeeded {
            Button("恢复配置…") {
                model.errorMessage = nil
                model.recoveryWizardPresented = true
                model.settingsDestination = .automation
                model.showSettings()
            }
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            if !showsTouchPreview && !showsTouchAuthorizationPreview { model.refreshTouchPermission() }
        }
    }

    private func panelSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        SettingsPanelGroupBox(title) {
            content()
        }
    }

    private var panelHeight: CGFloat {
        let baseHeight: CGFloat = model.frontLightAvailable ? (model.isColorEink ? 580 : 530) : 390
        let desired = baseHeight + (model.touchIsTouchDeviceConnected || showsTouchPreview || showsTouchAuthorizationPreview ? 86 : 0)
        return min(desired, max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 60))
    }

    private var touchPreviewStatus: String {
        if showsTouchAuthorizationPreview { "需要辅助功能权限" }
        else if showsTouchPreview { "正在映射" }
        else { model.touchUIState.statusText }
    }

    private var connectionHeader: some View {
        let presentation = model.connectionPresentation

        return HStack(spacing: 9) {
            ConnectionStatusIcon(presentation: presentation, size: 20)
                .foregroundStyle(model.isConnected ? .primary : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.headline)
                Text(model.deviceState?.profile.displayName ?? "PaperLike 13.3K")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if presentation.showsProgress {
                ProgressView().controlSize(.small)
            } else if presentation.allowsReconnect {
                Button {
                    model.reconnect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新连接")
                .accessibilityLabel("重新连接显示器")
                .frame(minWidth: 24, minHeight: 24)
            }
            Button {
                model.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置")
            .accessibilityLabel("打开设置")
            .frame(minWidth: 24, minHeight: 24)
            Button {
                model.quit()
            } label: {
                Image(systemName: "power")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("退出")
            .accessibilityLabel("退出 PaperLike Native")
            .frame(minWidth: 24, minHeight: 24)
        }
        .padding(.horizontal, 16)
        .padding(.vertical,8)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    @ViewBuilder
    private var displayControls: some View {
        Group {
            HStack(spacing: 40) {
                Picker(
                    "显示模式",
                    selection: Binding(
                        get: { model.deviceState?.mode ?? .text },
                        set: model.selectMode
                    )
                ) {
                    Text("网页").tag(DisplayMode.web)
                    Text("文字").tag(DisplayMode.text)
                    Text("图像").tag(DisplayMode.image)
                    Text("动态").tag(DisplayMode.active)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)

                Button {
                    model.performRefresh()
                } label: {
                    Label("刷新", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
            }

            HStack(alignment: .top, spacing: 12) {
                valueSlider(
                    title: "对比度", value: model.deviceState?.threshold ?? 5, range: 1...9,
                    action: model.setThreshold
                )
                .frame(maxWidth: .infinity)
                valueSlider(
                    title: "刷新速度", value: model.deviceState?.speed ?? 3, range: 1...5,
                    statusText: model.deviceState?.speed.map { "上次设置 \($0)" } ?? "未读取",
                    action: model.setSpeed
                )
                .frame(maxWidth: .infinity)
            }

            if model.isColorEink {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("色调对比度")
                        Spacer()
                        if model.saturation != 0.5 {
                            Button {
                                model.setSaturation(0.5)
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("恢复默认")
                        }
                        Text(String(format: "%.0f%%", model.saturation * 200))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { model.saturation },
                            set: { model.setSaturation($0) }
                        ),
                        in: 0.0...1.0
                    )
                }
            }

        }
        .disabled(!model.isConnected || model.isCommandRunning)
    }

    @ViewBuilder
    private var frontLightControls: some View {
        Group {
            Menu {
                Section("模式") {
                    Button("关闭") { model.setFrontLightMode(0) }
                    Button("冷光") { model.setFrontLightMode(1) }
                    Button("暖光") { model.setFrontLightMode(2) }
                    Button("混合") { model.setFrontLightMode(3) }
                }

                if model.frontLightPresets.isEmpty {
                    Section("自定义预设") {
                        Text("还没有预设")
                    }
                } else {
                    Section("自定义预设") {
                        ForEach(model.frontLightPresets) { preset in
                            Button(preset.name) { model.applyFrontLightPreset(preset) }
                        }
                    }
                    Menu("管理预设") {
                        ForEach(model.frontLightPresets) { preset in
                            Button("删除 \(preset.name)", role: .destructive) {
                                    model.deleteFrontLightPreset(preset.id)
                            }
                        }
                    }
                }

                Divider()
                Button("保存当前设置为预设…") {
                    newFrontLightPresetName = ""
                    showingFrontLightPresetNamePrompt = true
                }
            } label: {
                Label("模式：\(frontLightModeTitle)", systemImage: "sun.max")
            }
            .alert("添加前光预设", isPresented: $showingFrontLightPresetNamePrompt) {
                TextField("预设名称", text: $newFrontLightPresetName)
                Button("取消", role: .cancel) { }
                Button("保存") {
                    model.saveFrontLightPreset(name: newFrontLightPresetName)
                }
            } message: {
                Text("保存当前前光模式、亮度和色温。")
            }

            HStack(alignment: .top, spacing: 12) {
                valueSlider(
                    title: "亮度",
                    value: model.brightnessDraft,
                    range: 0...100,
                    resetValue: 50,
                    showsTickMarks: false,
                    action: model.setBrightness
                )
                .disabled(model.deviceState?.frontLightMode == 0)
                .frame(maxWidth: .infinity)
                valueSlider(
                    title: "色温",
                    value: model.temperatureDraft,
                    range: 0...100,
                    resetValue: 50,
                    showsTickMarks: false,
                    action: model.setTemperature
                )
                .disabled(model.deviceState?.frontLightMode == 0)
                .frame(maxWidth: .infinity)
            }
        }
        .disabled(!model.isConnected || model.isCommandRunning)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var frontLightModeTitle: String {
        switch model.deviceState?.frontLightMode ?? 3 {
        case 0: "关闭"
        case 1: "冷光"
        case 2: "暖光"
        default: "混合"
        }
    }

    @ViewBuilder
    private var automationControls: some View {
        Group {
            if model.lightingAutomationAvailable {
                HStack {
                    Text("前光自动化")
                    Spacer()
                    Toggle(
                        "前光自动化",
                        isOn: Binding(
                            get: { model.automationSettings.isEnabled },
                            set: {
                                model.automationSettings.isEnabled = $0
                                model.saveAutomationSettings()
                            }
                        )
                    )
                    .labelsHidden()
                }
                if model.automationSettings.isEnabled
                    || model.automationStatus.failureMessage != nil
                {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.automationSummary)
                        if model.automationStatus.failureMessage != nil {
                            Button("重试") { model.retryAutomation() }
                                .disabled(!model.isConnected || model.isCommandRunning)
                        }
                        if let next = model.automationStatus.nextBoundary {
                            Text("下次：\(next.automationBoundaryText)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if model.automationSettings.isEnabled {
                        LightingPauseMenu(model: model)
                    }
                }
            }

            HStack {
                Text("自动清残影")
                Spacer()
                Toggle(
                    "自动清残影",
                    isOn: Binding(
                        get: { model.settings.autoRefreshEnabled },
                        set: {
                            model.settings.autoRefreshEnabled = $0
                            model.saveSettings()
                        }
                    )
                )
                .labelsHidden()
            }
            if model.settings.autoRefreshEnabled {
                HStack {
                    Stepper(
                        "清残影间隔：\(model.settings.autoRefreshIntervalSeconds) 秒",
                        value: $model.settings.autoRefreshIntervalSeconds,
                        in: 30...600,
                        step: 15
                    )
                    .disabled(!model.settings.autoRefreshEnabled)
                }
                .onChange(of: model.settings.autoRefreshIntervalSeconds) {
                    model.saveSettings()
                }
            }
        }
    }

    private func valueSlider(
        title: String,
        value: Int,
        range: ClosedRange<Double>,
        resetValue: Int? = nil,
        showsTickMarks: Bool = true,
        statusText: String? = nil,
        action: @escaping (Int) -> Void
    ) -> some View {
        QuickPanelValueSlider(title: title, value: value, range: range,
            resetValue: resetValue, showsTickMarks: showsTickMarks,
            statusText: statusText, action: action)
    }
}

private struct QuickPanelValueSlider: View {
    let title: String
    let value: Int
    let range: ClosedRange<Double>
    let resetValue: Int?
    let showsTickMarks: Bool
    let statusText: String?
    let action: (Int) -> Void
    @State private var draft: Double
    @State private var isEditing = false

    init(title: String, value: Int, range: ClosedRange<Double>, resetValue: Int?,
         showsTickMarks: Bool, statusText: String?, action: @escaping (Int) -> Void) {
        self.title = title; self.value = value; self.range = range
        self.resetValue = resetValue; self.showsTickMarks = showsTickMarks
        self.statusText = statusText; self.action = action
        _draft = State(initialValue: Double(value))
    }

    var body: some View {
        let sliderValue = Binding(get: { draft }, set: {
            draft = $0
            if !isEditing { action(Int($0.rounded())) }
        })
        let editingChanged: (Bool) -> Void = { editing in
            isEditing = editing
            if !editing { action(Int(draft.rounded())) }
        }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                if let resetValue, value != resetValue {
                    Button {
                        action(resetValue)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("恢复默认")
                    .accessibilityLabel("恢复\(title)默认值")
                }
                Text(isEditing ? "\(Int(draft.rounded()))" : (statusText ?? "\(value)"))
                    .font(statusText == nil ? .body : .caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if showsTickMarks {
                Slider(value: sliderValue, in: range, step: 1, onEditingChanged: editingChanged)
                    .accessibilityLabel(title)
            } else {
                Slider(value: sliderValue, in: range, onEditingChanged: editingChanged)
                    .accessibilityLabel(title)
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: value) { if !isEditing { draft = Double(value) } }
    }
}

#if DEBUG
    struct QuickPanelView_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                preview(touch: false)
                    .previewDisplayName("普通")
                preview(touch: true)
                    .previewDisplayName("含触控")
                preview(needsAccessibility: true)
                    .previewDisplayName("需辅助功能授权")
            }
        }

        private static func preview(touch: Bool = false, needsAccessibility: Bool = false) -> some View {
            let model = AppModel()
            model.mockConnectedForPreview()
            return QuickPanelView(
                model: model,
                showsTouchPreview: touch,
                showsTouchAuthorizationPreview: needsAccessibility
            )
        }
    }
#endif
