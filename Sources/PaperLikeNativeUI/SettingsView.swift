import SwiftUI

enum SettingsWindowLayout {
    static let initialSize = CGSize(width: 820, height: 620)
    static let minimumSize = CGSize(width: 620, height: 620)

    static var previewSize: CGSize {
        CGSize(
            width: max(initialSize.width, minimumSize.width),
            height: max(initialSize.height, minimumSize.height)
        )
    }
}

public enum SettingsDestination: CaseIterable, Hashable, Identifiable {
    case general
    case appAdaptation
    case automation
    case touch
    case configurations
    case diagnostics
    case experiments
    case about

    static var sidebarItems: [Self] {
        [.general, .appAdaptation, .automation, .experiments, .about]
    }

    public var id: Self { self }

    public var title: String {
        switch self {
        case .general: "通用"
        case .appAdaptation: "应用自适应"
        case .automation, .configurations: "场景"
        case .touch: "触控"
        case .diagnostics: "关于"
        case .experiments: "实验室"
        case .about: "关于"
        }
    }

    public var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .appAdaptation: "cpu"
        case .automation: "clock.badge.checkmark"
        case .touch: "hand.tap"
        case .configurations: "clock.badge.checkmark"
        case .diagnostics: "info.circle"
        case .experiments: "flask"
        case .about: "info.circle"
        }
    }
}

struct SettingsGroupBox<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            GroupBox(label: Text(title).padding(4)) {
                VStack(alignment: .leading, spacing: 4) { content }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 12, trailing: 4))
        }
    }
}

struct SettingsPanelGroupBox<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox(label: Text(title).padding(4)) {
            VStack(alignment: .leading, spacing: 4) { content }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsList<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        List { content }
            .listStyle(.inset)
            .toggleStyle(.switch)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    func centeredInSettingsList() -> some View {
        frame(maxWidth: .infinity, alignment: .center)
    }
}

public struct SettingsView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $model.settingsDestination) {
                ForEach(SettingsDestination.sidebarItems) { destination in
                    Label(
                        destination.title,
                        systemImage: destination.symbolName
                    )
                    .tag(destination)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 340, max: 360)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: SettingsWindowLayout.minimumSize.width, minHeight: SettingsWindowLayout.minimumSize.height)
        .sheet(item: $model.editingAutomationRule) { rule in
            ScheduleRuleEditorView(rule: rule) {
                model.updateAutomationRule($0)
            }
            .id(rule.id)
        }
        .alert("PaperLike Native", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
            if model.configurationRecoveryNeeded {
                Button("恢复配置…") {
                    model.errorMessage = nil
                    model.recoveryWizardPresented = true
                    model.settingsDestination = .automation
                }
            }
        } message: { Text(model.errorMessage ?? "") }
        .onAppear { model.refreshTouchPermission(); model.reloadAccessibilitySettings(); model.refreshLoginItemStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshTouchPermission()
            model.reloadAccessibilitySettings()
            model.refreshLoginItemStatus()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch model.settingsDestination ?? .general {
        case .general:
            generalSettings
        case .appAdaptation:
            AppAdaptationSettingsView(model: model)
        case .automation, .configurations:
            AutomationSettingsView(model: model)
        case .touch, .experiments:
            ExperimentalFeaturesView(model: model)
        case .diagnostics, .about:
            aboutSettings
        }
    }

    private var generalSettings: some View {
        SettingsList {
                SettingsGroupBox("系统") {
                    Toggle(
                        "登录时启动",
                        isOn: Binding(
                            get: { model.loginItemEnabled },
                            set: model.setLoginItem
                        )
                    )
                    Text(model.loginItemStatus.description)
                        .font(.callout).foregroundStyle(.secondary)
                    if model.loginItemStatus == .requiresApproval || model.loginItemStatus == .notFound {
                        Button("打开系统登录项设置") { model.openLoginItemSettings() }
                            .centeredInSettingsList()
                    }
                }

                SettingsGroupBox("系统辅助功能（影响整个 Mac）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            "提高对比度",
                            isOn: Binding(
                                get: { model.systemIncreaseContrast },
                                set: model.setSystemIncreaseContrast
                            )
                        )

                        Toggle(
                            "减少透明度",
                            isOn: Binding(
                                get: { model.systemReduceTransparency },
                                set: model.setSystemReduceTransparency
                            )
                        )
                    }
                    .disabled(model.isSystemSettingsUpdating)
                    if model.isSystemSettingsUpdating { ProgressView().controlSize(.small) }
                    Button("自动化授权设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                    }
                    .centeredInSettingsList()
                }

                SettingsGroupBox("全局快捷键") {
                    if !model.hotKeyRegistrationIssues.isEmpty {
                        Label("部分已保存快捷键尚未生效", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("实际注册与已保存组合不一致：" + model.hotKeyRegistrationIssues.map(\.title).joined(separator: "、"))
                            .font(.callout)
                        Button("重试已保存快捷键") { model.retrySavedHotKeys() }
                    }
                    ViewThatFits(in: .horizontal) {
                        shortcuts(columns: [GridItem(.flexible()), GridItem(.flexible())])
                            .frame(minWidth: 420)
                        shortcuts(columns: [GridItem(.flexible())])
                    }
                }
        }
        .onChange(of: model.settings) {
            model.saveSettings()
        }
    }

    private func shortcuts(columns: [GridItem]) -> some View {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ShortcutRecorderView(
                            title: "切换显示模式",
                            definition: $model.settings.modeHotKey
                        )
                        ShortcutRecorderView(
                            title: "快速刷新",
                            definition: $model.settings.refreshHotKey
                        )
                        ShortcutRecorderView(
                            title: "增加对比度",
                            definition: $model.settings.thresholdUpHotKey
                        )
                        ShortcutRecorderView(
                            title: "降低对比度",
                            definition: $model.settings.thresholdDownHotKey
                        )
                    }
    }

    private var aboutSettings: some View {
        SettingsList {
                SettingsGroupBox("关于") {
                    VStack(spacing: 4) {
                        Image(nsImage: PaperLikeArtwork.applicationIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .frame(maxWidth: .infinity)
                        Text("PaperLike Native")
                            .font(.title2)
                            .bold()
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Link(destination: URL(string: "https://x.com/teno_liu")!) {
                            HStack(spacing: 4) {
                                Text("X · @teno_liu")
                                Image(systemName: "arrow.up.forward.app")
                            }
                        }
                        .buttonStyle(.link)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                DiagnosticsView(model: model)
        }
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        let model = AppModel()
        model.mockConnectedForPreview()
        return SettingsView(model: model)
            .frame(width: SettingsWindowLayout.previewSize.width, height: SettingsWindowLayout.previewSize.height)
    }
}
#endif
