import SwiftUI

struct ConfigurationSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.allControlsPaused {
                SettingsGroupBox("自动控制已暂停") {
                    Button("恢复自动控制") { model.setAllControlsPaused(false) }
                        .centeredInSettingsList()
                }
            }
            SettingsGroupBox("场景") {
                VStack {
                    Text("我的场景")
                        .frame(maxWidth: .infinity, alignment: .center)
                    HStack {
                        Button("应用") {
                            if let preset = model.presets.first { model.applyPreset(preset) }
                        }
                        .disabled(!model.isConnected || model.isCommandRunning || model.presets.isEmpty)
                        .centeredInSettingsList()
                        Button("更新我的场景") { model.saveCurrentPreset() }
                            .disabled(!model.isConnected || model.isCommandRunning)
                            .centeredInSettingsList()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            SettingsGroupBox("备份与恢复") {
                VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("导出配置…") { model.exportConfiguration() }
                        .centeredInSettingsList()
                    Button("导入配置…") { model.previewConfigurationImport() }
                        .disabled(model.isCommandRunning)
                        .centeredInSettingsList()
                }
                .frame(maxWidth: .infinity)
                Button("恢复向导") { model.recoveryWizardPresented.toggle() }
                    .centeredInSettingsList()
                if model.recoveryWizardPresented {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("1. 保留原始配置").font(.headline)
                        Button(model.recoveryArchiveExported ? "重新导出原始备份…" : "导出原始备份…") { model.exportRawConfiguration() }
                        Text("原始备份保留损坏数据供排查；恢复需选择此前导出的配置JSON。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("2. 从配置文件恢复").font(.headline)
                        Button("选择配置文件…") { model.previewConfigurationImport() }
                            .disabled(!model.recoveryArchiveExported || model.isCommandRunning)
                        Text("3. 检查后恢复运行").font(.headline)
                        Button("恢复自动控制") { model.resumeImportedConfiguration() }
                            .disabled(!model.recoveryImportCompleted || !model.allControlsPaused || model.isCommandRunning)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                }
            }
        }
        .sheet(item: $model.pendingImport) { backup in
            VStack(alignment: .leading, spacing: 16) {
                Text("确认导入配置").font(.title2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(backup.impactSummary(comparedTo: model.configurationBackup()), id: \.self) { Text($0) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
                Text("确认后立即保存设置并更换快捷键，暂停自动控制。已有手动画面不会立即恢复；恢复自动控制时会应用校准，匹配规则可能切换当前显示模式与前光。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("取消", role: .cancel) { model.pendingImport = nil }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("替换配置", role: .destructive) { model.confirmConfigurationImport() }
                        .buttonStyle(.bordered)
                        .disabled(model.isCommandRunning)
                }
            }.padding(24).frame(width: 460)
        }
    }
}
