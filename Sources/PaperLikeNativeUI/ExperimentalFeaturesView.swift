import SwiftUI

struct ExperimentalFeaturesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsList {
                SettingsGroupBox("画面曲线 · 驱动实验") {
                    DisclosureGroup("通道曲线校准") {
                        Toggle("启用独立通道曲线", isOn: Binding(get: { model.isGrayscaleEnabled }, set: model.setGrayscaleEnabled))
                        curveSlider("红色阈值", value: model.grayscaleRedThreshold, range: 0...1, set: model.setGrayscaleRedThreshold)
                        curveSlider("绿色阈值", value: model.grayscaleGreenThreshold, range: 0...1, set: model.setGrayscaleGreenThreshold)
                        curveSlider("蓝色阈值", value: model.grayscaleBlueThreshold, range: 0...1, set: model.setGrayscaleBlueThreshold)
                        curveSlider("曲线强度", value: model.grayscaleContrast, range: 1...20, set: model.setGrayscaleContrast)
                    }
                    .disabled(!model.displayConnected)
                    Button("恢复打开应用前的画面曲线") { model.restoreDisplayCalibration() }
                        .centeredInSettingsList()
                }
                SettingsGroupBox("画面抖动 · 驱动实验") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("画面抖动", isOn: Binding(get: { model.ditheringEnabled }, set: model.setDithering))
                            .disabled(!model.ditheringAvailable)
                        Button("恢复打开应用前的值") { model.restoreExperimentalDithering() }
                            .disabled(!model.ditheringAvailable)
                            .centeredInSettingsList()
                        if let result = model.driverResultMessage { Text(result).foregroundStyle(.secondary) }
                    }
                }
                SettingsGroupBox("均匀性 · 未验证效果") {
                    Toggle("均匀性驱动选项", isOn: Binding(get: { model.enhancementEnabled }, set: model.setEnhancement))
                        .disabled(!model.enhancementAvailable)
                }
                TouchSettingsView(model: model)
        }
        .onAppear {
            model.reloadDitheringState()
            model.reloadEnhancementState()
        }
    }

    private func curveSlider(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping @MainActor @Sendable (Double) -> Void) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: value.formatted(.number.precision(.fractionLength(2))))
            Slider(value: Binding(get: { value }, set: { set($0) }), in: range)
                .accessibilityLabel(title)
        }
    }
}
