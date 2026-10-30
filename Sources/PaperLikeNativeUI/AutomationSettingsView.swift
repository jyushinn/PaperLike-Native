import PaperlikeLocalization
import PaperlikeCore
import SwiftUI

struct LightingPauseMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu(L("暂停与恢复")) {
            Button(L("暂停 30 分钟")) { model.pauseLighting(minutes: 30) }
            Button(L("暂停到下个时段")) { model.pauseLighting() }
                .disabled(model.automationStatus.nextBoundary == nil)
            Button(L("今天不再自动切换")) { model.pauseLighting(untilTomorrow: true) }
            Divider()
            Button(L("立即恢复")) { model.resumeLighting() }
        }
        .disabled(model.allControlsPaused)
    }
}

struct AutomationSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsList {
            statusGroup
            ruleList
            ConfigurationSettingsView(model: model)
        }
    }

    private var statusGroup: some View {
        SettingsGroupBox(L("前光自动化")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("启用前光自动化"))
                    Spacer()
                    Toggle(
                        L("启用前光自动化"),
                        isOn: Binding(
                            get: { model.automationSettings.isEnabled },
                            set: {
                                model.automationSettings.isEnabled = $0
                                model.saveAutomationSettings()
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!model.lightingAutomationAvailable)
                }

                if !model.lightingAutomationAvailable {
                    Label(
                        L("当前设备不支持前光"),
                        systemImage: "lightbulb.slash"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Text(model.automationSummary)
                        if model.automationStatus.failureMessage != nil {
                            Button(L("重试")) { model.retryAutomation() }
                                .disabled(!model.isConnected || model.isCommandRunning)
                                .centeredInSettingsList()
                    }
                }

                HStack {
                    if let next = model.automationStatus.nextBoundary,
                       model.automationSettings.isEnabled {
                        Text(L("下次切换：\(next.automationBoundaryText)"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    LightingPauseMenu(model: model)
                    .disabled(
                        !model.lightingAutomationAvailable
                            || !model.automationSettings.isEnabled
                    )
                }
            }
        }
    }

    private var ruleHeader: some View {
        HStack {
            Button {
                let current = model.deviceState
                model.editingAutomationRule = LightingScheduleRule(
                    name: L("新时间段"),
                    weekdays: Set(Weekday.allCases),
                    start: MinuteOfDay(hour: 9, minute: 0),
                    end: MinuteOfDay(hour: 18, minute: 0),
                    configuration: LightingConfiguration(
                        frontLightMode: current?.frontLightMode ?? 3,
                        brightness: current?.brightness ?? 50,
                        temperature: current?.temperature ?? 50
                    )
                )
            } label: {
                Label(L("添加规则"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.automationRulesForEditing.count >= SettingsValidation.maximumRules)
            .centeredInSettingsList()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var ruleList: some View {
        SettingsGroupBox(L("时间规则")) {
            VStack(alignment: .leading, spacing: 10) {
                ruleHeader
                Text(L("\(model.automationRulesForEditing.count)/\(SettingsValidation.maximumRules) 条规则")).font(.caption).foregroundStyle(.secondary)
                if let message = model.automationRuleRepairMessage {
                    Label(model.automationRuleDraft.rules == nil ? L("现有规则需要修复") : L("规则修改尚未保存"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(message).font(.callout)
                    Text(L("修正所有无效规则后自动保存。关闭应用将丢弃未保存的修改。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if model.automationRuleDraft.rules != nil {
                        Button(L("放弃未保存修改")) { model.discardAutomationRuleDraft() }
                    }
                }
                if LightingScheduleEngine.hasConflicts(rules: model.automationRulesForEditing) {
                    Label(L("时间重叠，靠后规则优先"), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if model.automationRulesForEditing.isEmpty {
                    Label(L("还没有时间规则"), systemImage: "clock")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(model.automationRulesForEditing.enumerated()), id: \.element.id) { index, rule in
                        ruleRow(rule, index: index)
                        if index < model.automationRulesForEditing.count - 1 {
                            Divider().padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private func ruleRow(
        _ rule: LightingScheduleRule,
        index: Int
    ) -> some View {
        HStack(spacing: 12) {
            Toggle(
                L("启用规则：\(rule.name)"),
                isOn: Binding(
                    get: { rule.isEnabled },
                    set: {
                        var changed = rule
                        changed.isEnabled = $0
                        model.updateAutomationRule(changed)
                    }
                )
            )
            .labelsHidden()

            Button {
                model.editingAutomationRule = rule
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.name)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(
                        "\(rule.weekdays.automationText) · "
                            + "\(rule.start.displayText)–\(rule.end.displayText)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(
                        "\(rule.configuration.frontLightModeText) · "
                            + L("亮度 \(rule.configuration.brightness) · ")
                            + L("色温 \(rule.configuration.temperature)")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 4) {
                Button {
                    model.moveAutomationRules(
                        from: IndexSet(integer: index),
                        to: index - 1
                    )
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help(L("上移（冲突时优先级降低）"))

                Button {
                    model.moveAutomationRules(
                        from: IndexSet(integer: index),
                        to: index + 2
                    )
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(index == model.automationRulesForEditing.count - 1)
                .help(L("下移（冲突时优先级提高）"))
            }

            Menu {
                Button(L("编辑")) { model.editingAutomationRule = rule }
                Button(L("复制")) {
                    model.duplicateAutomationRule(id: rule.id)
                }
                .disabled(model.automationRulesForEditing.count >= SettingsValidation.maximumRules)
                Divider()
                Button(L("删除"), role: .destructive) {
                    model.deleteAutomationRules(
                        at: IndexSet(integer: index)
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 5)
        .opacity(rule.isEnabled ? 1 : 0.55)
    }
}

extension Weekday {
    static let automationOrder: [Weekday] = [
        .monday,
        .tuesday,
        .wednesday,
        .thursday,
        .friday,
        .saturday,
        .sunday
    ]

    var shortName: String {
        switch self {
        case .monday: L("一")
        case .tuesday: L("二")
        case .wednesday: L("三")
        case .thursday: L("四")
        case .friday: L("五")
        case .saturday: L("六")
        case .sunday: L("日")
        }
    }
}

extension Set where Element == Weekday {
    var automationText: String {
        if self == Set(Weekday.automationOrder) {
            return L("每天")
        }
        if self == Set(Weekday.automationOrder.prefix(5)) {
            return L("周一至周五")
        }
        if self == Set(Weekday.automationOrder.suffix(2)) {
            return L("周末")
        }
        return Weekday.automationOrder
            .filter(contains)
            .map { L("周\($0.shortName)") }
            .joined(separator: L("、"))
    }
}

extension MinuteOfDay {
    var displayText: String {
        String(format: "%02d:%02d", value / 60, value % 60)
    }
}

extension LightingConfiguration {
    var frontLightModeText: String {
        switch frontLightMode {
        case 0: L("关闭前光")
        case 1: L("冷光")
        case 2: L("暖光")
        default: L("混合光")
        }
    }
}

extension Date {
    var automationBoundaryText: String {
        formatted(
            .dateTime
                .weekday(.abbreviated)
                .hour()
                .minute()
                .locale(AppLanguage.current.locale)
        )
    }
}

#if DEBUG
struct AutomationSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        let model = AppModel()
        model.mockConnectedForPreview()
        return AutomationSettingsView(model: model)
    }
}
#endif
