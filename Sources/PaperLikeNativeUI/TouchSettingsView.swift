import SwiftUI
import CoreGraphics
import PaperlikeTouch

@MainActor
final class TouchDiagnosticsModel: ObservableObject {
    @Published var snapshot = TouchDiagnosticsSnapshot()
}

struct TouchSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showsDiagnostics = false

    var body: some View {
        Group {
                SettingsGroupBox("触控映射") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("启用触控映射", isOn: Binding(get: { model.touchSettings.isEnabled }, set: { model.setTouchEnabled($0) }))
                        LabeledContent("状态", value: model.touchUIState.statusText)
                        LabeledContent("坐标方案", value: model.touchCalibrationDescription)
                        HStack(spacing: 8) {
                            if !model.touchIsAccessibilityTrusted {
                                Button("请求辅助功能权限") { model.requestTouchAccessibility() }
                                    .centeredInSettingsList()
                                Button("重新检查授权") { model.refreshTouchPermission() }
                                    .centeredInSettingsList()
                            } else if model.touchStatus == .stopped && model.touchSettings.isEnabled && !model.allControlsPaused {
                                Button("继续触控") { model.resumeTouch() }
                                    .centeredInSettingsList()
                            } else if model.touchMappingActive {
                                Button("暂停触控") { model.pauseTouch() }
                                    .centeredInSettingsList()
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                SettingsGroupBox("目标显示器") {
                    Picker("输出到", selection: Binding<CGDirectDisplayID?>(get: { model.touchSelectedDisplayID }, set: { model.selectTouchDisplay(id: $0) })) {
                        Text("自动识别 PaperLike").tag(nil as CGDirectDisplayID?)
                        ForEach(model.touchAvailableDisplays, id: \.id) { display in
                            Text(display.name).tag(display.id as CGDirectDisplayID?)
                        }
                    }
                }

                SettingsGroupBox("滚动与物理惯性") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("自然滚动", isOn: Binding(
                            get: { model.touchSettings.isNaturalScrolling },
                            set: { model.setTouchNaturalScrolling($0) }
                        ))
                        Toggle("惯性滚动", isOn: Binding(
                            get: { model.touchSettings.isInertialScrollEnabled },
                            set: { model.setTouchInertialScrolling($0) }
                        ))
                        if model.touchSettings.isInertialScrollEnabled {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("惯性滑行阻尼 / 距离")
                                    Spacer()
                                    let friction = model.touchSettings.inertiaFriction
                                    let desc = friction < 0.88 ? "紧凑急停" : (friction > 0.94 ? "顺滑长滑行" : "均衡适中")
                                    Text(String(format: "%.2f (%@)", friction, desc))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Slider(
                                    value: Binding(
                                        get: { model.touchSettings.inertiaFriction },
                                        set: { model.setTouchInertiaFriction($0) }
                                    ),
                                    in: 0.82...0.97,
                                    step: 0.01
                                )
                                .accessibilityLabel("惯性滑行阻尼")
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("滚动灵敏度")
                                Spacer()
                                Text(String(format: "%.1fx", model.touchSettings.scrollSpeed))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { model.touchSettings.scrollSpeed },
                                    set: { model.setTouchScrollSpeed($0) }
                                ),
                                in: 0.5...3.0,
                                step: 0.1
                            )
                            .accessibilityLabel("滚动灵敏度")
                        }
                    }
                }

                SettingsGroupBox("手势增强与交互模式") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("单指滚动（长按拖拽）", isOn: Binding(
                            get: { model.touchSettings.isSingleFingerScrollEnabled },
                            set: { model.setTouchSingleFingerScroll($0) }
                        ))
                        .help("滑动以滚动，长按0.4秒以拖拽，轻触以点击。")

                        Divider()

                        Toggle("触控时隐藏光标", isOn: Binding(
                            get: { model.touchSettings.isCursorHiddenOnTouch },
                            set: { model.setTouchCursorHidden($0) }
                        ))
                        .help("使用鼠标或触控板时重新显示光标。")

                        Divider()

                        Toggle("捏合缩放（兼容应用）", isOn: Binding(
                            get: { model.touchSettings.isPinchToZoomEnabled },
                            set: { model.setTouchPinchToZoom($0) }
                        ))
                        Toggle("双指轻触右键", isOn: Binding(
                            get: { model.touchSettings.isTwoFingerRightClickEnabled },
                            set: { model.setTouchTwoFingerRightClick($0) }
                        ))
                    }
                }

                SettingsGroupBox("触控诊断") {
                    DisclosureGroup("实时传感器", isExpanded: $showsDiagnostics) {
                        TouchDiagnosticReadout(diagnostics: model.touchDiagnosticsModel)
                    }
                }

                SettingsGroupBox("校准与测试") {
                    DisclosureGroup("显示校准与触点测试") {
                        HStack(spacing: 8) {
                            Button("使用自动映射") { model.useAutomaticTouchCalibration() }
                                .centeredInSettingsList()
                            Button("四角校准") { model.beginTouchCalibration() }
                                .disabled(!model.touchIsTouchDeviceConnected || model.allControlsPaused)
                                .centeredInSettingsList()
                        }
                        .frame(maxWidth: .infinity)
                        Toggle("测试触点（不移动鼠标）", isOn: Binding(get: { model.touchIsTesting }, set: { model.setTouchTesting($0) }))
                            .disabled(!model.touchUIState.canToggleTesting || model.allControlsPaused)
                        if model.touchIsTesting {
                            Text(model.touchContactSummary).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
        }
        .sheet(isPresented: $model.touchCalibrationPresented) { TouchCalibrationView(model: model) }
        .onAppear { model.refreshTouchPermission() }
        .onChange(of: showsDiagnostics) { model.setTouchDiagnosticsVisible(showsDiagnostics) }
        .onDisappear {
            model.setTouchTesting(false)
            model.setTouchDiagnosticsVisible(false)
        }
    }
}

private struct TouchDiagnosticReadout: View {
    @ObservedObject var diagnostics: TouchDiagnosticsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack {
        Text("手势状态")
        .font(.subheadline)
        .foregroundColor(.secondary)
        Spacer()
        Text(diagnostics.snapshot.gestureState)
        .font(.system(.subheadline, design: .monospaced))
        .bold()
        .foregroundColor(diagnostics.snapshot.isInertiaActive ? .green : .accentColor)
        if diagnostics.snapshot.isInertiaActive {
        Text("惯性中")
        .font(.system(size: 10, weight: .bold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.green.opacity(0.15))
        .foregroundColor(.green)
        .cornerRadius(4)
        }
        }

        Divider()

        VStack(alignment: .leading, spacing: 2) {
        Text("触点传感器参数 (\(diagnostics.snapshot.contactCount) 指)")
        .font(.caption)
        .foregroundColor(.secondary)
        Text(diagnostics.snapshot.contactsDescription)
        .font(.system(.caption, design: .monospaced))
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .cornerRadius(4)
        }

        HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
        Text("双指间距")
        .font(.caption2)
        .foregroundColor(.secondary)
        Text(String(format: "%.1f pt", diagnostics.snapshot.twoFingerDistance))
        .font(.system(.caption, design: .monospaced))
        }
        Spacer()
        VStack(alignment: .leading, spacing: 2) {
        Text("速度 (Vx, Vy)")
        .font(.caption2)
        .foregroundColor(.secondary)
        Text(String(format: "%+.1f, %+.1f", diagnostics.snapshot.velocity.x, diagnostics.snapshot.velocity.y))
        .font(.system(.caption, design: .monospaced))
        }
        Spacer()
        VStack(alignment: .leading, spacing: 2) {
        Text("瞬时合速度")
        .font(.caption2)
        .foregroundColor(.secondary)
        Text(String(format: "%.1f pt/f", diagnostics.snapshot.speed))
        .font(.system(.caption, design: .monospaced))
        }
        }
        .padding(.top, 2)

        if !diagnostics.snapshot.lastAction.isEmpty {
        HStack {
        Text("最新动作")
        .font(.caption2)
        .foregroundColor(.secondary)
        Spacer()
        Text(diagnostics.snapshot.lastAction)
        .font(.system(.caption2, design: .monospaced))
        .foregroundColor(.blue)
        }
        }
        }
    }
}
