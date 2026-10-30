import PaperlikeLocalization
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

    private let panelWidth: CGFloat = 380

    public var body: some View {
        VStack(spacing: 0) {
            connectionHeader
            Divider()
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    if model.allControlsPaused {
                        Button(L("恢复自动控制")) { model.resumeImportedConfiguration() }
                            .frame(maxWidth: .infinity)
                    }
                    if !model.isConnected {
                        ContentUnavailableView(L("控制未连接"), systemImage: "cable.connector", description: Text(L("等待控制串口，视频与触控连接单独检测。")))
                        Button(L("重新连接")) { model.reconnect() }
                            .frame(maxWidth: .infinity)
                    } else {
                    panelSection(L("我的场景")) {
                        HStack {
                            Button(L("应用")) {
                                if let preset = model.presets.first { model.applyPreset(preset) }
                            }
                            .disabled(model.presets.isEmpty)
                            Spacer()
                            Button(L("保存场景"), systemImage: "square.and.arrow.down") {
                                model.saveCurrentPreset()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(!model.isConnected || model.isCommandRunning)

                    panelSection(L("显示")) {
                        displayControls
                    }
                    if model.frontLightAvailable {

                        panelSection(L("前光")) {
                            frontLightControls
                        }
                    }
                    }

                    panelSection(L("自动化")) {
                        automationControls
                    }
                    if showsTouchPreview || showsTouchAuthorizationPreview || model.touchIsTouchDeviceConnected || model.touchMappingActive || model.canResumeTouch {
                        panelSection(L("触控")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(touchPreviewStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    if showsTouchPreview {
                                        Button(L("暂停触控"), systemImage: "pause.circle") { }
                                            .disabled(true)
                                            .frame(maxWidth: .infinity)
                                    } else if model.touchMappingActive {
                                        Button(L("暂停触控"), systemImage: "pause.circle") { model.pauseTouch() }
                                            .frame(maxWidth: .infinity)
                                    } else if showsTouchAuthorizationPreview {
                                        Button(L("授权触控"), systemImage: "hand.tap") { }
                                            .frame(maxWidth: .infinity)
                                        Button(L("重新检查授权"), systemImage: "arrow.clockwise") { }
                                            .frame(maxWidth: .infinity)
                                    } else if !model.touchIsAccessibilityTrusted {
                                        Button(L("授权触控"), systemImage: "hand.tap") {
                                            model.requestTouchAccessibility()
                                        }
                                        .frame(maxWidth: .infinity)
                                        Button(L("重新检查授权"), systemImage: "arrow.clockwise") {
                                            model.refreshTouchPermission()
                                        }
                                        .frame(maxWidth: .infinity)
                                    } else if model.canResumeTouch {
                                        Button(L("继续触控"), systemImage: "play.circle") { model.resumeTouch() }
                                            .frame(maxWidth: .infinity)
                                    } else {
                                        Button(L("触控设置"), systemImage: "slider.horizontal.3") {
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
            .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .alert(
            "PaperLike Native",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button(L("好")) { model.errorMessage = nil }
            if model.configurationRecoveryNeeded {
            Button(L("恢复配置…")) {
                model.errorMessage = nil
                model.recoveryWizardPresented = true
                model.settingsDestination = .automation
                model.showSettings()
            }
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .id(model.language.resolvedIdentifier())
        .environment(\.locale, model.language.locale)
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

    private var touchPreviewStatus: String {
        if showsTouchAuthorizationPreview { L("需要辅助功能权限") }
        else if showsTouchPreview { L("正在映射") }
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
                Text(model.deviceState.map { "PaperLike 13.3K · \($0.profile.panelKind.displayText)" } ?? "PaperLike 13.3K")
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
                .help(L("重新连接"))
                .accessibilityLabel(L("重新连接显示器"))
                .frame(minWidth: 24, minHeight: 24)
            }
            Button {
                model.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(L("设置"))
            .accessibilityLabel(L("打开设置"))
            .frame(minWidth: 24, minHeight: 24)
            Button {
                model.quit()
            } label: {
                Image(systemName: "power")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(L("退出"))
            .accessibilityLabel(L("退出 PaperLike Native"))
            .frame(minWidth: 24, minHeight: 24)
        }
        .padding(.horizontal, 16)
        .padding(.vertical,8)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    @ViewBuilder
    private var displayControls: some View {
        Group {
            HStack(spacing: 8) {
                Picker(
                    L("显示模式"),
                    selection: Binding(
                        get: { model.deviceState?.mode ?? .text },
                        set: { model.selectMode($0) }
                    )
                ) {
                    Text(L("网页")).tag(DisplayMode.web)
                    Text(L("文字")).tag(DisplayMode.text)
                    Text(L("图像")).tag(DisplayMode.image)
                    Text(L("动态")).tag(DisplayMode.active)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)

                Button {
                    model.performRefresh()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .frame(width: 20)
                }
                .buttonStyle(.borderedProminent)
                .help(L("刷新"))
                .accessibilityLabel(L("快速刷新"))
            }

            HStack(alignment: .top, spacing: 12) {
                valueSlider(
                    title: L("对比度"), value: model.deviceState?.threshold ?? 5, range: 1...9,
                    action: model.setThreshold
                )
                .frame(maxWidth: .infinity)
                valueSlider(
                    title: L("速度"), value: model.deviceState?.speed ?? 3, range: 1...5,
                    statusText: model.deviceState?.speed.map { L("上次设置 \($0)") } ?? L("未读取"),
                    action: model.setSpeed
                )
                .frame(maxWidth: .infinity)
            }

            if model.isColorEink {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(L("色调对比度"))
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
                            .help(L("恢复默认"))
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
                Section(L("模式")) {
                    Button(L("关闭")) { model.setFrontLightMode(0) }
                    Button(L("冷光")) { model.setFrontLightMode(1) }
                    Button(L("暖光")) { model.setFrontLightMode(2) }
                    Button(L("混合")) { model.setFrontLightMode(3) }
                }

                if model.frontLightPresets.isEmpty {
                    Section(L("自定义预设")) {
                        Text(L("还没有预设"))
                    }
                } else {
                    Section(L("自定义预设")) {
                        ForEach(model.frontLightPresets) { preset in
                            Button(preset.name) { model.applyFrontLightPreset(preset) }
                        }
                    }
                    Menu(L("管理预设")) {
                        ForEach(model.frontLightPresets) { preset in
                            Button(L("删除 \(preset.name)"), role: .destructive) {
                                    model.deleteFrontLightPreset(preset.id)
                            }
                        }
                    }
                }

                Divider()
                Button(L("保存当前设置为预设…")) {
                    newFrontLightPresetName = ""
                    showingFrontLightPresetNamePrompt = true
                }
            } label: {
                Label(L("模式：\(frontLightModeTitle)"), systemImage: "sun.max")
            }
            .alert(L("添加前光预设"), isPresented: $showingFrontLightPresetNamePrompt) {
                TextField(L("预设名称"), text: $newFrontLightPresetName)
                Button(L("取消"), role: .cancel) { }
                Button(L("保存")) {
                    model.saveFrontLightPreset(name: newFrontLightPresetName)
                }
            } message: {
                Text(L("保存当前前光模式、亮度和色温。"))
            }

            HStack(alignment: .top, spacing: 12) {
                valueSlider(
                    title: L("亮度"),
                    value: model.brightnessDraft,
                    range: 0...100,
                    resetValue: 50,
                    showsTickMarks: false,
                    action: model.setBrightness
                )
                .disabled(model.deviceState?.frontLightMode == 0)
                .frame(maxWidth: .infinity)
                valueSlider(
                    title: L("色温"),
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
        case 0: L("关闭")
        case 1: L("冷光")
        case 2: L("暖光")
        default: L("混合")
        }
    }

    @ViewBuilder
    private var automationControls: some View {
        Group {
            if model.lightingAutomationAvailable {
                HStack {
                    Text(L("定时前光"))
                    Spacer()
                    Toggle(
                        L("定时前光"),
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
                            Button(L("重试")) { model.retryAutomation() }
                                .disabled(!model.isConnected || model.isCommandRunning)
                        }
                        if let next = model.automationStatus.nextBoundary {
                            Text(L("下次：\(next.automationBoundaryText)"))
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
                Text(L("自动清残影"))
                Spacer()
                Toggle(
                    L("自动清残影"),
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
                        L("清残影间隔：\(model.settings.autoRefreshIntervalSeconds) 秒"),
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
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let resetValue, value != resetValue {
                    Button {
                        action(resetValue)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("恢复默认"))
                    .accessibilityLabel(L("恢复\(title)默认值"))
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
                    .previewDisplayName(L("普通"))
                preview(touch: true)
                    .previewDisplayName(L("含触控"))
                preview(needsAccessibility: true)
                    .previewDisplayName(L("需辅助功能授权"))
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
