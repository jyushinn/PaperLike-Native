import PaperlikeCore
import SwiftUI

struct AppAdaptationSettingsView: View {
    @ObservedObject var model: AppModel

    // List of running applications
    private var runningApps: [(name: String, bundleId: String)] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (name: String, bundleId: String)? in
                guard let name = app.localizedName, let bid = app.bundleIdentifier else { return nil }
                return (name: name, bundleId: bid)
            }

        // Unique and sort
        var seen = Set<String>()
        var uniqueApps = [(name: String, bundleId: String)]()
        for app in apps {
            if !seen.contains(app.bundleId) {
                seen.insert(app.bundleId)
                uniqueApps.append(app)
            }
        }
        return uniqueApps.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        SettingsList {
                SettingsGroupBox("设置自适应") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("启用应用自适应")
                                .font(.headline)
                            Spacer()
                            Toggle("启用", isOn: Binding(
                                get: { model.settings.isAppAdaptationEnabled },
                                set: {
                                    model.settings.isAppAdaptationEnabled = $0
                                    model.saveSettings()
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }
                }

                if model.settings.isAppAdaptationEnabled || !model.appRulesForEditing.isEmpty {
                    SettingsGroupBox("新增匹配规则") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("手动输入 Bundle ID", isOn: $model.isCustomApp)
                                .font(.caption)

                            if model.isCustomApp {
                                HStack(spacing: 12) {
                                    TextField("应用名称（最多 120 字符）", text: $model.customAppName)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("Bundle ID（最多 255 字符）", text: $model.customBundleId)
                                        .textFieldStyle(.roundedBorder)
                                }
                                if (!model.customAppName.isEmpty || !model.customBundleId.isEmpty),
                                   let message = customAppValidationMessage {
                                    Text(message).font(.caption).foregroundStyle(.red)
                                }
                            } else {
                                Picker("选择运行中的应用", selection: $model.selectedBundleId) {
                                    if model.selectedBundleId.isEmpty {
                                        Text("--- 请选择应用 ---").tag("")
                                    }
                                    ForEach(runningApps, id: \.bundleId) { app in
                                        Text(app.name).tag(app.bundleId)
                                    }
                                }
                                .pickerStyle(.menu)
                            }

                            HStack(spacing: 20) {
                                Picker("显示模式", selection: $model.selectedMode) {
                                    Text("网页").tag(DisplayMode.web)
                                    Text("文字").tag(DisplayMode.text)
                                    Text("图像").tag(DisplayMode.image)
                                    Text("动态").tag(DisplayMode.active)
                                }
                                .frame(width: 200)

                                HStack {
                                    Text("对比度:")
                                    Slider(value: Binding(
                                        get: { Double(model.selectedThreshold) },
                                        set: { model.selectedThreshold = Int($0.rounded()) }
                                    ), in: 1...9, step: 1)
                                    Text("\(model.selectedThreshold)")
                                        .monospacedDigit()
                                        .frame(width: 15, alignment: .trailing)
                                }
                            }

                            HStack {
                                Button {
                                    addRule()
                                } label: {
                                    Label("添加规则", systemImage: "plus")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isAddDisabled)
                                .centeredInSettingsList()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    SettingsGroupBox("已有规则列表") {
                        Text("\(model.appRulesForEditing.count)/\(SettingsValidation.maximumRules) 条规则").font(.caption).foregroundStyle(.secondary)
                        if let message = model.appRuleRepairMessage {
                            Label(model.appRuleDraft.rules == nil ? "现有规则需要修复" : "规则修改尚未保存", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(message).font(.callout)
                            Text("修正所有无效规则后自动保存。关闭应用将丢弃未保存的修改。")
                                .font(.caption).foregroundStyle(.secondary)
                            if model.appRuleDraft.rules != nil {
                                Button("放弃未保存修改") { model.discardAppRuleDraft() }
                            }
                        }
                        if model.appRulesForEditing.isEmpty {
                            Text("暂无配置规则")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(model.appRulesForEditing) { rule in
                                    ruleRow(rule)
                                    if rule.id != model.appRulesForEditing.last?.id {
                                        Divider()
                                            .padding(.vertical, 8)
                                    }
                                }
                            }
                        }
                    }
                }
        }
        .onAppear {
            if model.selectedBundleId.isEmpty, let firstApp = runningApps.first {
                model.selectedBundleId = firstApp.bundleId
            }
        }
    }

    private var isAddDisabled: Bool {
        if model.appRulesForEditing.count >= SettingsValidation.maximumRules { return true }
        if model.isCustomApp {
            return customAppValidationMessage != nil
        } else {
            return model.selectedBundleId.isEmpty
        }
    }

    private var customAppValidationMessage: String? {
        do {
            try SettingsValidation.validateName(
                model.customAppName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let bundle = model.customBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            if bundle.isEmpty { return "请输入 Bundle ID。" }
            if bundle.count > 255 || bundle.utf8.count > 1_020 { return "Bundle ID 过长，请缩短。" }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func ruleRow(_ rule: AppAdaptationRule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("启用规则：\(rule.appName)", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { value in var updated = rule; updated.isEnabled = value; model.updateAppRule(updated) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("应用名称", text: Binding(
                        get: { rule.appName },
                        set: { value in var updated = rule; updated.appName = value; model.updateAppRule(updated) }
                    )).accessibilityLabel("应用名称")
                    TextField("Bundle ID", text: Binding(
                        get: { rule.bundleIdentifier },
                        set: { value in var updated = rule; updated.bundleIdentifier = value; model.updateAppRule(updated) }
                    )).font(.caption).accessibilityLabel("Bundle ID")
                }
                Spacer()
                Button(role: .destructive) { deleteRule(rule) } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("删除规则")
                .accessibilityLabel("删除规则：\(rule.appName)")
            }
            HStack {
                Picker("显示模式", selection: Binding(
                    get: { rule.mode },
                    set: { value in var updated = rule; updated.mode = value; model.updateAppRule(updated) }
                )) {
                    Text("网页").tag(DisplayMode.web)
                    Text("文字").tag(DisplayMode.text)
                    Text("图像").tag(DisplayMode.image)
                    Text("动态").tag(DisplayMode.active)
                }.accessibilityLabel("\(rule.appName) 的显示模式")
                Stepper("对比度 \(rule.threshold)", value: Binding(
                    get: { rule.threshold },
                    set: { value in var updated = rule; updated.threshold = value; model.updateAppRule(updated) }
                ), in: 1...9)
                    .accessibilityLabel("\(rule.appName) 的对比度")
                    .fixedSize()
            }
        }
    }

    private func addRule() {
        let name: String
        let bid: String
        if model.isCustomApp {
            name = model.customAppName.trimmingCharacters(in: .whitespacesAndNewlines)
            bid = model.customBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            guard let app = runningApps.first(where: { $0.bundleId == model.selectedBundleId }) else { return }
            name = app.name
            bid = app.bundleId
        }

        // Check duplicate
        if model.appRulesForEditing.contains(where: { $0.bundleIdentifier == bid }) {
            model.errorMessage = "已存在该应用程序的匹配规则。"
            return
        }

        let newRule = AppAdaptationRule(bundleIdentifier: bid, appName: name, mode: model.selectedMode, threshold: model.selectedThreshold)
        guard model.updateAppRule(newRule) else { return }

        // Reset
        if model.isCustomApp {
            model.customAppName = ""
            model.customBundleId = ""
        }
    }

    private func deleteRule(_ rule: AppAdaptationRule) {
        model.deleteAppRule(id: rule.id)
    }
}
