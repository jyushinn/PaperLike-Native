import PaperlikeLocalization
import PaperlikeCore
import SwiftUI

private final class ScheduleRuleEditorModel: ObservableObject {
    @Published var draft: LightingScheduleRule
    @Published var frontLightMode: Int
    @Published var brightness: Double
    @Published var temperature: Double

    init(rule: LightingScheduleRule) {
        draft = rule
        frontLightMode = rule.configuration.frontLightMode
        brightness = Double(rule.configuration.brightness)
        temperature = Double(rule.configuration.temperature)
    }
}

struct ScheduleRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor: ScheduleRuleEditorModel

    let onSave: (LightingScheduleRule) -> Bool

    init(
        rule: LightingScheduleRule,
        onSave: @escaping (LightingScheduleRule) -> Bool
    ) {
        _editor = StateObject(wrappedValue: ScheduleRuleEditorModel(rule: rule))
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("时间规则")).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Form {
                Section {
                    TextField(L("名称"), text: $editor.draft.name, prompt: Text(L("例如：白天")))
                        .textFieldStyle(.roundedBorder)
                        .help(L("最多120个字符"))
                    if let message = nameValidationMessage {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    Toggle(L("启用规则"), isOn: $editor.draft.isEnabled)
                }

                Section(L("重复")) {
                    HStack(spacing: 6) {
                        ForEach(Weekday.automationOrder, id: \.self) { weekday in
                            Toggle(isOn: weekdayBinding(weekday)) {
                                Text(weekday.shortName)
                                    .frame(maxWidth: .infinity, minHeight: 22)
                            }
                            .toggleStyle(.button)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(L("周\(weekday.shortName)"))
                        }
                    }
                    if editor.draft.weekdays.isEmpty {
                        Text(L("至少选择一天")).font(.caption).foregroundStyle(.red)
                    }
                }

                Section(L("时间")) {
                    DatePicker(L("开始"), selection: minuteBinding(\.start),
                               displayedComponents: .hourAndMinute)
                    DatePicker(editor.draft.end <= editor.draft.start ? L("结束（次日）") : L("结束"),
                               selection: minuteBinding(\.end),
                               displayedComponents: .hourAndMinute)
                }

                Section(L("前光")) {
                    LabeledContent(L("模式")) {
                        Picker(L("模式"), selection: $editor.frontLightMode) {
                            Text(L("关闭")).tag(0)
                            Text(L("冷光")).tag(1)
                            Text(L("暖光")).tag(2)
                            Text(L("混合")).tag(3)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: .infinity)
                    }
                    valueSlider(title: L("亮度"), value: $editor.brightness)
                        .disabled(editor.frontLightMode == 0)
                    valueSlider(title: L("色温"), value: $editor.temperature)
                        .disabled(editor.frontLightMode == 0)
                }
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .controlSize(.regular)

            Divider()
            HStack {
                Button(L("取消"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("保存")) {
                    var result = editor.draft
                    result.name = editor.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    result.configuration = LightingConfiguration(
                        frontLightMode: editor.frontLightMode,
                        brightness: Int(editor.brightness.rounded()),
                        temperature: Int(editor.temperature.rounded())
                    )
                    if onSave(result) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 500, height: 560)
    }

    private var canSave: Bool {
        nameValidationMessage == nil && !editor.draft.weekdays.isEmpty
    }

    private var nameValidationMessage: String? {
        do {
            try SettingsValidation.validateName(
                editor.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func weekdayBinding(_ weekday: Weekday) -> Binding<Bool> {
        Binding(
            get: { editor.draft.weekdays.contains(weekday) },
            set: { selected in
                if selected { editor.draft.weekdays.insert(weekday) }
                else { editor.draft.weekdays.remove(weekday) }
            }
        )
    }

    private func minuteBinding(
        _ keyPath: WritableKeyPath<LightingScheduleRule, MinuteOfDay>
    ) -> Binding<Date> {
        Binding(
            get: {
                date(from: editor.draft[keyPath: keyPath])
            },
            set: {
                let components = Calendar.current.dateComponents(
                    [.hour, .minute],
                    from: $0
                )
                editor.draft[keyPath: keyPath] = MinuteOfDay(
                    hour: components.hour ?? 0,
                    minute: components.minute ?? 0
                )
            }
        )
    }

    private func date(from minute: MinuteOfDay) -> Date {
        Calendar.current.date(
            bySettingHour: minute.value / 60,
            minute: minute.value % 60,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private func valueSlider(
        title: String,
        value: Binding<Double>
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: value, in: 0...100)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Int(value.wrappedValue.rounded()))")
                Text("\(Int(value.wrappedValue.rounded()))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct ScheduleRuleEditorView_Previews: PreviewProvider {
    static var previews: some View {
        ScheduleRuleEditorView(
            rule: LightingScheduleRule(
                name: L("白天"),
                weekdays: [.monday],
                start: MinuteOfDay(hour: 8, minute: 0),
                end: MinuteOfDay(hour: 18, minute: 0),
                configuration: LightingConfiguration(frontLightMode: 1, brightness: 50, temperature: 50)
            )
        ) { _ in true }
    }
}
