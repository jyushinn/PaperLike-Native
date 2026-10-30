import PaperlikeLocalization
import AppKit
import UniformTypeIdentifiers
import Combine
import PaperlikeCore
import PaperlikeTouch
import SerialTransport
import SwiftUI

public struct TouchUIState: Equatable, Sendable {
    public let status: TouchMappingStatus
    public let isEnabled: Bool
    public let isTesting: Bool
    public let isTouchDeviceConnected: Bool
    public let isAccessibilityTrusted: Bool
    public let targetDisplay: TouchDisplay?

    public init(
        status: TouchMappingStatus,
        isEnabled: Bool,
        isTesting: Bool,
        isTouchDeviceConnected: Bool,
        isAccessibilityTrusted: Bool,
        targetDisplay: TouchDisplay?
    ) {
        self.status = status
        self.isEnabled = isEnabled
        self.isTesting = isTesting
        self.isTouchDeviceConnected = isTouchDeviceConnected
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.targetDisplay = targetDisplay
    }

    public var canEnable: Bool {
        isTouchDeviceConnected
            && isAccessibilityTrusted
            && targetDisplay != nil
            && !isTesting
    }

    public var isMappingActive: Bool {
        status == .ready && isEnabled && !isTesting
    }

    public var canToggleTesting: Bool {
        isTouchDeviceConnected || isTesting
    }

    public var statusText: String {
        switch status {
        case .stopped:
            L("已暂停")
        case .disabled:
            L("未启用")
        case .accessibilityRequired:
            L("需要辅助功能权限")
        case .deviceUnavailable:
            L("当前不支持")
        case .displaySelectionRequired:
            L("请选择目标显示器")
        case .ready:
            L("正在映射")
        case .testing:
            L("正在测试")
        case .error:
            L("触控出错")
        }
    }

    public var detailText: String {
        switch status {
        case .stopped:
            L("触控输出已停止，可在高级实验室继续。")
        case .disabled:
            L("触控已关闭；启用后会记住你的选择。")
        case .accessibilityRequired:
            L("仅点击权限按钮时才会显示 macOS 提示。")
        case .deviceUnavailable:
            L("仅支持 PaperLike 13.3K 彩色触控型号；串口控制不受影响。")
        case .displaySelectionRequired:
            L("未能唯一识别 PaperLike 画面，请手动选择。")
        case .ready:
            L("单指移动、点击与拖动；双指滚动或轻点右键。")
        case .testing:
            L("只显示触点数据，绝不发布鼠标事件。")
        case let .error(message):
            message
        }
    }
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public var language: AppLanguage = .current {
        willSet {
            UserDefaults.standard.set(newValue.rawValue, forKey: AppLanguage.preferenceKey)
        }
        didSet {
            settingsWindow?.title = L("设置")
        }
    }
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var isCommandRunning = false
    @Published var errorMessage: String?
    @Published var settings: AppSettings
    @Published var automationSettings: LightingAutomationSettings
    @Published private(set) var appRuleDraft = RuleEditingDraft<AppAdaptationRule>()
    @Published private(set) var automationRuleDraft = RuleEditingDraft<LightingScheduleRule>()
    @Published private(set) var hotKeyRegistrationIssues: [HotKeyAction] = []
    @Published private(set) var automationStatus =
        LightingAutomationStatus.inactive
    @Published var ditheringEnabled = false
    @Published var enhancementEnabled = false
    @Published var saturation: Double = 0.5
    @Published var isGrayscaleEnabled = false
    @Published var grayscaleRedThreshold = 0.5
    @Published var grayscaleGreenThreshold = 0.5
    @Published var grayscaleBlueThreshold = 0.5
    @Published var grayscaleContrast = 6.0
    @Published private(set) var ditheringAvailable = false
    @Published private(set) var enhancementAvailable = false
    @Published private(set) var rtcResultMessage: String?
    @Published private(set) var driverResultMessage: String?
    @Published var systemReduceTransparency = false
    @Published var systemIncreaseContrast = false
    @Published private(set) var isSystemSettingsUpdating = false
    @Published var editingAutomationRule: LightingScheduleRule?
    @Published var settingsDestination: SettingsDestination? = .general
    @Published private(set) var activeSerialPath: String?
    @Published private(set) var loginItemStatus = LoginItemStatus.notRegistered
    var loginItemEnabled: Bool { loginItemStatus.isRequested }
    @Published var brightnessDraft = 0
    @Published var temperatureDraft = 0
    @Published var selectedBundleId = ""
    @Published var selectedMode = DisplayMode.text
    @Published var selectedThreshold = 5
    @Published var customBundleId = ""
    @Published var customAppName = ""
    @Published var isCustomApp = false
    @Published private(set) var touchStatus: TouchMappingStatus = .stopped
    @Published private(set) var touchLatestFrame: TouchFrame?
    @Published private(set) var touchSettings: TouchMappingSettings = .default
    @Published private(set) var touchAvailableDisplays: [TouchDisplay] = []
    @Published private(set) var touchIsTesting = false
    @Published private(set) var touchIsTouchDeviceConnected = false
    @Published private(set) var touchIsAccessibilityTrusted = false
    @Published private(set) var touchTargetDisplay: TouchDisplay?
    let touchDiagnosticsModel = TouchDiagnosticsModel()
    @Published var touchCalibrationPresented = false
    @Published private(set) var allControlsPaused = UserDefaults.standard.bool(forKey: "PaperLikeNative.AllControlsPaused")
    @Published private(set) var lightingVerified = false
    @Published private(set) var recentOperations: [OperationRecord] = []
    @Published var presets: [DisplayPreset] = []
    @Published var frontLightPresets: [FrontLightPreset] = []
    @Published var pendingImport: ConfigurationBackup?
    @Published var pauseDescription: String?

    let controller: PaperlikeDeviceController
    private let touchMapping: TouchMappingService

    private let monitor = SerialDeviceMonitor()
    private let settingsStore = AppSettingsStore()
    private let automationSettingsStore = LightingAutomationSettingsStore()
    private let hotKeys = HotKeyService()
    private let loginItem = LoginItemService()
    private let displayDriver = DisplayDriverService.shared
    private var systemSettingsTask: Task<Void, Never>?
    private var savedAutomationSettings: LightingAutomationSettings
    private var savedSettings: AppSettings
    private var eventTask: Task<Void, Never>?
    private var automationEventTask: Task<Void, Never>?
    private var lightingCommandEventTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var generalCommandRunning = false
    private var displaySliderQueue = DisplaySliderQueue()
    private var lastManualState: (mode: DisplayMode, threshold: Int)? = nil
    private var lastAppliedApp: String? = nil
    private var appAdaptationTask: Task<Void, Never>?
    private var calibrationTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectionRevision = 0
    private var isShuttingDown = false
    private var isSystemSleeping = false
    private var touchWasPaused = false
    private var lightingCommandSession = LightingCommandSessionState()

    private lazy var lightingCommandCoordinator =
        DebouncedLightingCommandCoordinator { [controller] command in
            switch command.control {
            case .brightness:
                try await controller.setBrightness(command.value)
            case .temperature:
                try await controller.setTemperature(command.value)
            }
        }

    private lazy var autoRefresh = AutoRefreshService(
        isConnected: { [weak self] in
            await MainActor.run { self?.isConnected == true }
        },
        isIdle: { [weak self] in
            await MainActor.run { self?.isCommandRunning == false }
        },
        refresh: { [weak self] in
            guard let self else { return }
            try await self.performAutomaticRefresh()
        }
    )

    private lazy var lightingAutomation = LightingAutomationService(
        currentConfig: { [weak self] in
            guard let self = self else { return nil }
            return await MainActor.run {
                guard let state = self.deviceState else { return nil }
                return LightingConfiguration(
                    frontLightMode: state.frontLightMode,
                    brightness: state.brightness,
                    temperature: state.temperature
                )
            }
        },
        apply: { [weak self] configuration in
            guard let self else { return }
            try await self.applyAutomatedLighting(configuration)
        }
    )

    public init(
        controller: PaperlikeDeviceController = PaperlikeDeviceController(),
        touchMappingService: TouchMappingService = TouchMappingService()
    ) {
        self.controller = controller
        touchMapping = touchMappingService
        let loadedSettings = settingsStore.load()
        let loadedAutomationSettings = automationSettingsStore.load()
        settings = loadedSettings
        automationSettings = loadedAutomationSettings
        savedSettings = loadedSettings
        savedAutomationSettings = loadedAutomationSettings
        var presetRecoveryNeeded = false
        presets = PresetStore.load(onCorruption: { presetRecoveryNeeded = true })
        frontLightPresets = FrontLightPresetStore.load(onCorruption: { presetRecoveryNeeded = true })
        saturation = loadedSettings.saturationValue
        isGrayscaleEnabled = loadedSettings.isGrayscaleEnabled
        grayscaleRedThreshold = loadedSettings.redThreshold
        grayscaleGreenThreshold = loadedSettings.greenThreshold
        grayscaleBlueThreshold = loadedSettings.blueThreshold
        grayscaleContrast = loadedSettings.contrastSlope

        #if DEBUG
        // UI previews must not connect to hardware or change system settings.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1"
            || ProcessInfo.processInfo.environment["PAPERLIKE_UI_PREVIEW"] == "1" { return }
        #endif

        // Preserve the system's existing registration; first launch makes no opt-in choice.
        refreshLoginItemStatus()

        eventTask = Task { [weak self] in
            await self?.observeController()
        }
        monitorTask = Task { [weak self] in
            await self?.observeSerialDevices()
        }
        automationEventTask = Task { [weak self] in
            await self?.observeAutomation()
        }
        lightingCommandEventTask = Task { [weak self] in
            await self?.observeLightingCommands()
        }
        configureAutoRefresh()
        configureLightingAutomation(applyImmediately: true)
        configureSystemObservers()
        configureTouchMapping()
        reloadDitheringState()
        reloadEnhancementState()
        if !allControlsPaused { applyCalibration(reportFailure: false) }
        do {
            try configureHotKeys(using: loadedSettings)
        } catch {
            errorMessage = L("快捷键冲突，未启用冲突组合。")
        }
        if settingsStore.recoveredCorruptData || automationSettingsStore.recoveredCorruptData || touchMapping.recoveredCorruptSettings
            || presetRecoveryNeeded {
            configurationRecoveryNeeded = true
            errorMessage = L("部分设置无法读取，原始数据已保留。请检查设置或从备份恢复。")
        }
        systemReduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        systemIncreaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadAccessibilitySettings() }
            .store(in: &cancellables)
    }

    isolated deinit {
        systemSettingsTask?.cancel()
        eventTask?.cancel()
        automationEventTask?.cancel()
        lightingCommandEventTask?.cancel()
        monitorTask?.cancel()
        reconnectTask?.cancel()
        appAdaptationTask?.cancel()
        calibrationTask?.cancel()
        if let settingsWindowObserver { NotificationCenter.default.removeObserver(settingsWindowObserver) }
        do { try displayDriver.restore() } catch { NSLog("PaperLike display restore failed: %@", String(describing: error)) }
    }

    var deviceState: DeviceState? {
        guard case let .connected(_, state) = connectionState else {
            return nil
        }
        return state
    }

    var isConnected: Bool {
        deviceState != nil
    }

    var frontLightAvailable: Bool {
        deviceState?.frontLightAvailable == true
    }

    var lightingAutomationAvailable: Bool {
        !isConnected || frontLightAvailable
    }

    var isColorEink: Bool {
        deviceState?.profile.panelKind == .color
    }

    var touchUIState: TouchUIState {
        TouchUIState(
            status: touchStatus,
            isEnabled: touchSettings.isEnabled,
            isTesting: touchIsTesting,
            isTouchDeviceConnected: touchIsTouchDeviceConnected,
            isAccessibilityTrusted: touchIsAccessibilityTrusted,
            targetDisplay: touchTargetDisplay
        )
    }

    var touchMappingActive: Bool {
        touchUIState.isMappingActive
    }

    var touchSelectedDisplayID: CGDirectDisplayID? {
        switch touchSettings.displaySelection {
        case .automatic:
            nil
        case let .display(displayID):
            displayID
        case let .stable(identifier):
            touchAvailableDisplays.first { $0.stableID == identifier }?.id
        }
    }

    var touchContactSummary: String {
        guard let frame = touchLatestFrame else {
            return L("等待触点…")
        }
        guard !frame.contacts.isEmpty else {
            return L("当前 0 个触点")
        }
        let coordinates = frame.contacts.prefix(3).map { contact in
            "#\(contact.id) (\(contact.x), \(contact.y))"
        }
        return L("\(frame.contacts.count) 个触点：") + coordinates.joined(separator: "  ")
    }

    public var connectionPresentation: ConnectionPresentation {
        if case let .connected(_, state) = connectionState {
            return ConnectionPresentation(state: .connected(name: state.profile.displayName, state: state))
        }
        return ConnectionPresentation(state: connectionState)
    }

    var connectionTitle: String {
        connectionPresentation.title
    }

    @Published private(set) var paperlikeRefreshRate: Double?

    var connectionDetail: String {
        let base = connectionPresentation.detail(serialPath: activeSerialPath)
        if let hz = paperlikeRefreshRate {
            return base + L("  |  系统刷新率: \(Int(round(hz))) Hz")
        }
        return base
    }

    func reconnect() {
        startConnectionLoop(force: true)
    }

    func selectMode(_ mode: DisplayMode) {
        cancelAppAdaptationForManualChange()
        runCommand(verifyDisplay: true) { [controller] in
            try await controller.setMode(mode)
        }
    }

    func setThreshold(_ value: Int) {
        guard isConnected else { return }
        displaySliderQueue.submit(.threshold(value))
        flushDisplaySliders()
    }

    private func sendThreshold(_ value: Int) {
        cancelAppAdaptationForManualChange()
        runCommand(verifyDisplay: true) { [controller] in
            try await controller.setThreshold(value)
            try await controller.refresh()
        }
    }

    func applyModeAndThreshold(_ mode: DisplayMode, threshold: Int) {
        cancelAppAdaptationForManualChange()
        runCommand(verifyDisplay: true) { [controller] in
            try await controller.setMode(mode)
            try await controller.setThreshold(threshold)
            try await controller.refresh()
        }
    }

    func setSpeed(_ value: Int) {
        guard isConnected else { return }
        displaySliderQueue.submit(.speed(value))
        flushDisplaySliders()
    }

    private func sendSpeed(_ value: Int) {
        runCommand { [controller] in
            try await controller.setSpeed(value)
            try await controller.refresh()
        }
    }

    func setFrontLightMode(_ value: Int) {
        runManualLightingCommand { [controller] in
            try await controller.setFrontLightMode(value)
        }
    }

    func saveFrontLightPreset(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let state = deviceState, frontLightAvailable,
              !name.isEmpty, name.count <= 120,
              !frontLightPresets.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            errorMessage = L("请连接显示器，输入名称，并避免使用重复名称。")
            return
        }
        let preset = FrontLightPreset(
            name: name,
            configuration: LightingConfiguration(
                frontLightMode: state.frontLightMode,
                brightness: brightnessDraft,
                temperature: temperatureDraft
            )
        )
        do {
            let updated = frontLightPresets + [preset]
            try FrontLightPresetStore.save(updated)
            frontLightPresets = updated
            recordOperation(L("前光预设"), L("已保存：\(name)"))
        } catch {
            errorMessage = L("保存前光预设失败：\(error.localizedDescription)")
        }
    }

    func deleteFrontLightPreset(_ id: UUID) {
        let updated = frontLightPresets.filter { $0.id != id }
        do {
            try FrontLightPresetStore.save(updated)
            frontLightPresets = updated
        } catch {
            errorMessage = L("删除前光预设失败：\(error.localizedDescription)")
        }
    }

    func applyFrontLightPreset(_ preset: FrontLightPreset) {
        guard preset.isValid, isConnected, frontLightAvailable, !isCommandRunning else { return }
        let configuration = preset.configuration
        brightnessDraft = configuration.brightness
        temperatureDraft = configuration.temperature
        lightingVerified = false
        runManualLightingCommand { [controller] in
            try await controller.setFrontLightMode(configuration.frontLightMode)
            if configuration.frontLightMode != 0 {
                try await controller.setBrightness(configuration.brightness)
                try await controller.setTemperature(configuration.temperature)
            }
        }
    }

    func setBrightness(_ value: Int) {
        lightingVerified = false
        brightnessDraft = value
        guard isConnected, frontLightAvailable, !generalCommandRunning else {
            brightnessDraft = deviceState?.brightness ?? brightnessDraft
            return
        }
        guard let submission = lightingCommandSession.submit(
            control: .brightness,
            value: value
        ) else {
            brightnessDraft = deviceState?.brightness ?? brightnessDraft
            return
        }
        updateCommandRunning()
        Task {
            let accepted = await lightingCommandCoordinator.submit(submission)
            await handleLightingSubmission(
                accepted: accepted,
                submission: submission
            )
        }
    }

    func setTemperature(_ value: Int) {
        lightingVerified = false
        temperatureDraft = value
        guard isConnected, frontLightAvailable, !generalCommandRunning else {
            temperatureDraft = deviceState?.temperature ?? temperatureDraft
            return
        }
        guard let submission = lightingCommandSession.submit(
            control: .temperature,
            value: value
        ) else {
            temperatureDraft = deviceState?.temperature ?? temperatureDraft
            return
        }
        updateCommandRunning()
        Task {
            let accepted = await lightingCommandCoordinator.submit(submission)
            await handleLightingSubmission(
                accepted: accepted,
                submission: submission
            )
        }
    }

    func performRefresh() {
        runCommand { [controller] in
            try await controller.refresh()
        }
    }

    func cycleMode() {
        guard let current = deviceState?.mode,
              let index = DisplayMode.allCases.firstIndex(of: current)
        else {
            return
        }
        let modes = DisplayMode.allCases
        selectMode(modes[(index + 1) % modes.count])
    }

    func adjustThreshold(by amount: Int) {
        guard let value = deviceState?.threshold else {
            return
        }
        setThreshold(min(9, max(1, value + amount)))
    }

    func setDithering(_ enabled: Bool) {
        do {
            try displayDriver.setDitheringEnabled(enabled)
            ditheringEnabled = enabled
            ditheringAvailable = true
            driverResultMessage = enabled
                ? L("已开启画面抖动。")
                : L("已关闭画面抖动。")
        } catch {
            reloadDitheringState()
            driverResultMessage = L("无法读取或修改这台显示器的抖动设置。")
            errorMessage = L("无法修改抖动设置。")
        }
    }

    func setEnhancement(_ enabled: Bool) {
        do {
            try displayDriver.setEnhancementEnabled(enabled)
            enhancementEnabled = enabled
            enhancementAvailable = true
        } catch {
            reloadEnhancementState()
            errorMessage = L("当前 macOS 显示驱动不支持显示增强。")
        }
    }

    func applyCalibration(reportFailure: Bool = true) {
        guard !allControlsPaused, !isSystemSleeping else { return }
        do {
            try displayDriver.applyDisplayCalibration(
            saturation: saturation,
            redThreshold: grayscaleRedThreshold,
            greenThreshold: grayscaleGreenThreshold,
            blueThreshold: grayscaleBlueThreshold,
            contrastSlope: grayscaleContrast,
            isGrayscaleEnabled: isGrayscaleEnabled
            )
            driverResultMessage = nil
        } catch {
            driverResultMessage = L("画面曲线未应用，可重新连接后重试。")
            if reportFailure { errorMessage = L("画面曲线未应用：\(error.localizedDescription)") }
        }
    }

    private func scheduleCalibration() {
        calibrationTask?.cancel()
        calibrationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !self.isShuttingDown else { return }
            if self.saveSettings() { self.applyCalibration() }
        }
    }

    func setSaturation(_ value: Double) {
        saturation = value
        settings.saturationValue = value
        scheduleCalibration()
    }

    func setGrayscaleEnabled(_ enabled: Bool) {
        isGrayscaleEnabled = enabled
        settings.isGrayscaleEnabled = enabled
        scheduleCalibration()
    }

    func setGrayscaleRedThreshold(_ value: Double) {
        grayscaleRedThreshold = value
        settings.redThreshold = value
        scheduleCalibration()
    }

    func setGrayscaleGreenThreshold(_ value: Double) {
        grayscaleGreenThreshold = value
        settings.greenThreshold = value
        scheduleCalibration()
    }

    func setGrayscaleBlueThreshold(_ value: Double) {
        grayscaleBlueThreshold = value
        settings.blueThreshold = value
        scheduleCalibration()
    }

    func setGrayscaleContrast(_ value: Double) {
        grayscaleContrast = value
        settings.contrastSlope = value
        scheduleCalibration()
    }

    @discardableResult
    func saveSettings() -> Bool {
        defer { refreshHotKeyRegistrationStatus() }
        var candidate = settings
        candidate.autoRefreshIntervalSeconds = max(
            30,
            candidate.autoRefreshIntervalSeconds
        )
        let hotKeysChanged = [candidate.modeHotKey, candidate.refreshHotKey, candidate.thresholdUpHotKey, candidate.thresholdDownHotKey]
            != [savedSettings.modeHotKey, savedSettings.refreshHotKey, savedSettings.thresholdUpHotKey, savedSettings.thresholdDownHotKey]
        var hotKeysApplied = false
        do {
            try candidate.validate()
            guard candidate != savedSettings else { return true }
            let refreshChanged = candidate.autoRefreshEnabled != savedSettings.autoRefreshEnabled
                || candidate.autoRefreshIntervalSeconds != savedSettings.autoRefreshIntervalSeconds
            let adaptationChanged = candidate.isAppAdaptationEnabled != savedSettings.isAppAdaptationEnabled
                || candidate.rules != savedSettings.rules
            if hotKeysChanged {
                try configureHotKeys(using: candidate)
                hotKeysApplied = true
            }
            try settingsStore.save(candidate)
            settings = candidate
            savedSettings = candidate
            if refreshChanged { configureAutoRefresh() }
            if adaptationChanged, let app = NSWorkspace.shared.frontmostApplication {
                handleActiveApplicationChanged(app)
            }
            return true
        } catch {
            settings = savedSettings
            var failure = error.localizedDescription
            if hotKeysApplied {
                do { try configureHotKeys(using: savedSettings) }
                catch { failure += L("；快捷键恢复未完成：\(error.localizedDescription)") }
            }
            synchronizeCalibrationDrafts()
            errorMessage = L("设置未保存：\(failure)")
            return false
        }
    }

    @discardableResult
    func saveAutomationSettings() -> Bool {
        do {
            try automationSettingsStore.save(automationSettings)
            savedAutomationSettings = automationSettings
            configureLightingAutomation(applyImmediately: true)
            return true
        } catch {
            automationSettings = savedAutomationSettings
            errorMessage = L("自动化设置未保存：\(error.localizedDescription)")
            return false
        }
    }

    var appRulesForEditing: [AppAdaptationRule] { appRuleDraft.rules ?? settings.rules }
    var automationRulesForEditing: [LightingScheduleRule] { automationRuleDraft.rules ?? automationSettings.rules }
    var appRuleRepairMessage: String? {
        let issues = SettingsValidation.appRuleIssues(appRulesForEditing)
        return appRuleDraft.message ?? (issues.isEmpty ? nil : issues.joined(separator: " "))
    }
    var automationRuleRepairMessage: String? {
        let issues = SettingsValidation.automationRuleIssues(automationRulesForEditing)
        return automationRuleDraft.message ?? (issues.isEmpty ? nil : issues.joined(separator: " "))
    }

    func discardAppRuleDraft() { appRuleDraft.discard() }
    func discardAutomationRuleDraft() { automationRuleDraft.discard() }

    private func stageAppRules(_ rules: [AppAdaptationRule]) {
        var candidate = settings
        candidate.rules = rules
        var draft = appRuleDraft
        draft.update(rules, validate: { _ in try candidate.validate() }, save: { _ in
            self.settings = candidate
            guard self.saveSettings() else {
                throw SettingsValidationError.invalid(self.errorMessage ?? L("设置未保存。"))
            }
        })
        appRuleDraft = draft
    }

    private func stageAutomationRules(_ rules: [LightingScheduleRule]) {
        var candidate = automationSettings
        candidate.rules = rules
        var draft = automationRuleDraft
        draft.update(rules, validate: { _ in try candidate.validate() }, save: { _ in
            self.automationSettings = candidate
            guard self.saveAutomationSettings() else {
                throw SettingsValidationError.invalid(self.errorMessage ?? L("自动化设置未保存。"))
            }
        })
        automationRuleDraft = draft
    }

    // A completed editor is accepted into the visible draft even if other legacy rules
    // still need repair. No settings or runtime changes occur until all rules validate.
    @discardableResult
    func updateAppRule(_ rule: AppAdaptationRule) -> Bool {
        var rules = appRulesForEditing
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule }
        else { rules.append(rule) }
        stageAppRules(rules)
        return true
    }

    func deleteAppRule(id: UUID) {
        stageAppRules(appRulesForEditing.filter { $0.id != id })
    }

    func addAutomationRule() {
        let current = deviceState
        updateAutomationRule(LightingScheduleRule(
            name: L("新时间段"),
            weekdays: Set(Weekday.allCases),
            start: MinuteOfDay(hour: 9, minute: 0),
            end: MinuteOfDay(hour: 18, minute: 0),
            configuration: LightingConfiguration(
                frontLightMode: current?.frontLightMode ?? 3,
                brightness: current?.brightness ?? 50,
                temperature: current?.temperature ?? 50
            )
        ))
    }

    @discardableResult
    func updateAutomationRule(_ rule: LightingScheduleRule) -> Bool {
        var rules = automationRulesForEditing
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule }
        else { rules.append(rule) }
        stageAutomationRules(rules)
        return true
    }

    func duplicateAutomationRule(id: UUID) {
        guard let rule = automationRulesForEditing.first(where: { $0.id == id }) else { return }
        let suffix = L(" 副本")
        var prefix = String(rule.name.prefix(SettingsValidation.maximumNameLength - suffix.count))
        while prefix.utf8.count + suffix.utf8.count > SettingsValidation.maximumNameUTF8Bytes {
            prefix.removeLast()
        }
        updateAutomationRule(LightingScheduleRule(
            name: prefix + suffix,
            isEnabled: rule.isEnabled,
            weekdays: rule.weekdays,
            start: rule.start,
            end: rule.end,
            configuration: rule.configuration
        ))
    }

    func deleteAutomationRules(at offsets: IndexSet) {
        var rules = automationRulesForEditing
        for offset in offsets.sorted(by: >) { rules.remove(at: offset) }
        stageAutomationRules(rules)
    }

    func moveAutomationRules(from offsets: IndexSet, to destination: Int) {
        var rules = automationRulesForEditing
        let moving = offsets.sorted().map { rules[$0] }
        for offset in offsets.sorted(by: >) { rules.remove(at: offset) }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertion = max(0, min(rules.count, destination - removedBeforeDestination))
        rules.insert(contentsOf: moving, at: insertion)
        stageAutomationRules(rules)
    }

    func pauseAutomationUntilNextBoundary() {
        Task {
            await lightingAutomation.noteManualOverride()
        }
    }

    func syncDeviceClock() {
        guard !isCommandRunning, isConnected else {
            return
        }
        setGeneralCommandRunning(true)
        rtcResultMessage = nil
        Task {
            do {
                let result = try await controller.syncRealTimeClock()
                switch result {
                case .acknowledged:
                    rtcResultMessage = L("设备已确认时间同步。")
                case .sentWithoutAcknowledgement:
                    rtcResultMessage = L("同步命令已发送；当前固件没有返回确认。")
                }
            } catch {
                errorMessage = L("设备时间同步失败。")
            }
            setGeneralCommandRunning(false)
        }
    }

    func reloadDitheringState() {
        do {
            ditheringEnabled = try displayDriver.ditheringEnabled()
            ditheringAvailable = true
        } catch {
            ditheringAvailable = false
        }
    }

    func reloadEnhancementState() {
        do {
            enhancementEnabled = try displayDriver.enhancementEnabled()
            enhancementAvailable = true
        } catch {
            enhancementAvailable = false
        }
    }

    func restoreExperimentalDithering() {
        do {
            try displayDriver.restoreDithering()
            reloadDitheringState()
            driverResultMessage = L("已恢复打开应用前的抖动设置。")
        } catch {
            driverResultMessage = L("恢复失败，请重新连接显示器后再试。")
            errorMessage = L("无法恢复抖动设置。")
        }
    }

    func restoreDisplayCalibration() {
        calibrationTask?.cancel()
        do {
            try displayDriver.restoreDisplayCalibration()
            saturation = 0.5
            isGrayscaleEnabled = false
            settings.saturationValue = 0.5
            settings.isGrayscaleEnabled = false
            saveSettings()
            driverResultMessage = L("已恢复打开应用前的画面曲线。")
        } catch {
            driverResultMessage = L("恢复失败，原值备份仍保留；请连接原显示器后重试。")
            errorMessage = driverResultMessage
        }
    }

    func setTouchEnabled(_ enabled: Bool) {
        touchWasPaused = false
        if !allControlsPaused && !isSystemSleeping { touchMapping.start() }
        touchMapping.setEnabled(enabled)
    }

    var touchCalibrationDescription: String {
        switch touchMapping.calibrationSource {
        case .manual: L("已保存的校准")
        case .automaticHID: L("自动读取设备坐标范围")
        case .automaticFallback: L("自动使用此型号默认范围")
        }
    }

    func useAutomaticTouchCalibration() {
        touchMapping.useAutomaticCalibration()
    }

    func pauseTouch() {
        touchWasPaused = true
        touchMapping.pause()
    }

    var canResumeTouch: Bool {
        touchWasPaused && touchSettings.isEnabled && touchIsAccessibilityTrusted && !allControlsPaused
    }

    func resumeTouch() {
        guard !allControlsPaused else { return }
        touchWasPaused = false
        touchMapping.start()
    }

    func requestTouchAccessibility() {
        touchMapping.requestAccessibility()
    }

    func refreshTouchPermission() {
        touchMapping.refresh()
    }

    func setTouchTesting(_ testing: Bool) {
        guard !testing || !allControlsPaused else { return }
        if testing {
            guard touchIsTouchDeviceConnected else {
                errorMessage = L("未检测到 PaperLike 13.3K 彩色触控 HID 设备。")
                return
            }
            touchMapping.start()
        }
        touchMapping.setTesting(testing)
    }

    func beginTouchCalibration() {
        setTouchTesting(true)
        guard touchIsTesting else {
            return
        }
        touchCalibrationPresented = true
    }

    func cancelTouchCalibration() {
        touchCalibrationPresented = false
        touchMapping.setTesting(false)
    }

    func saveTouchCalibration(_ calibration: TouchCalibration) {
        touchCalibrationPresented = false
        touchMapping.setCalibration(calibration)
        touchMapping.setTesting(false)
    }

    func selectTouchDisplay(id: CGDirectDisplayID?) {
        let selection = id.map(TouchDisplaySelection.display) ?? .automatic
        touchMapping.setDisplaySelection(selection)
    }

    func restoreTouchDefaults() {
        touchMapping.restoreDefaults()
    }

    func setTouchNaturalScrolling(_ enabled: Bool) {
        touchMapping.updateGestureSettings(isNaturalScrolling: enabled)
    }

    func setTouchScrollSpeed(_ speed: Double) {
        touchMapping.updateGestureSettings(scrollSpeed: speed)
    }

    func setTouchInertialScrolling(_ enabled: Bool) {
        touchMapping.updateGestureSettings(isInertialScrollEnabled: enabled)
    }

    func setTouchInertiaFriction(_ friction: Double) {
        touchMapping.updateGestureSettings(inertiaFriction: friction)
    }

    func setTouchSingleFingerScroll(_ enabled: Bool) {
        touchMapping.updateGestureSettings(isSingleFingerScrollEnabled: enabled)
    }

    func setTouchCursorHidden(_ hidden: Bool) {
        touchMapping.updateGestureSettings(isCursorHiddenOnTouch: hidden)
    }

    func setTouchPinchToZoom(_ enabled: Bool) {
        touchMapping.updateGestureSettings(isPinchToZoomEnabled: enabled)
    }

    func setTouchTwoFingerRightClick(_ enabled: Bool) {
        touchMapping.updateGestureSettings(isTwoFingerRightClickEnabled: enabled)
    }

    func refreshLoginItemStatus() { loginItemStatus = loginItem.status }
    func openLoginItemSettings() { loginItem.openSettings() }

    func setLoginItem(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            refreshLoginItemStatus()
        } catch {
            errorMessage = L("无法修改登录启动设置：\(error.localizedDescription)")
            refreshLoginItemStatus()
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    public func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        systemSettingsTask?.cancel()
        monitor.stop()
        eventTask?.cancel()
        automationEventTask?.cancel()
        lightingCommandEventTask?.cancel()
        monitorTask?.cancel()
        reconnectTask?.cancel()
        appAdaptationTask?.cancel()
        calibrationTask?.cancel()
        cancellables.removeAll()
        if let settingsWindowObserver {
            NotificationCenter.default.removeObserver(settingsWindowObserver)
            self.settingsWindowObserver = nil
        }
        if let sheet = settingsWindow?.attachedSheet {
            settingsWindow?.endSheet(sheet)
        }
        settingsWindow?.close()
        settingsWindow?.contentViewController = nil
        settingsWindow = nil
        let autoRefresh = autoRefresh
        let lightingAutomation = lightingAutomation
        let controller = controller
        Task {
            await autoRefresh.stop()
            await lightingAutomation.stop()
            await controller.disconnect()
        }
        touchMapping.shutdown()
        do { try displayDriver.restore() }
        catch { recordOperation(L("显示恢复"), L("恢复失败，原值备份仍保留"), failed: true) }
    }

    private func runCommand(
        verifyDisplay: Bool = false,
        _ action: @escaping @Sendable () async throws -> Void,
        onFailure: (@MainActor () -> Void)? = nil
    ) {
        guard !isCommandRunning, isConnected else {
            return
        }
        setGeneralCommandRunning(true)
        Task {
            do {
                try await action()
                if verifyDisplay {
                    do {
                        if try await controller.verifyDisplayConfiguration() {
                            recordOperation(L("手动操作"), L("设备已确认"))
                        } else {
                            errorMessage = L("设备读回值与目标不一致，界面已更新为实际值。")
                            recordOperation(L("手动操作"), L("读回与目标不一致"), failed: true)
                        }
                    } catch PaperlikeDeviceError.timedOut {
                        recordOperation(L("手动操作"), L("指令已发送，未获得读回确认"))
                    }
                } else {
                    recordOperation(L("手动操作"), L("指令已发送，未读回"))
                }
            } catch {
                onFailure?()
                errorMessage = L("操作未完成，部分设置可能已生效：\(error.localizedDescription)")
                recordOperation(L("手动操作"), L("执行未完成"), failed: true)
            }
            setGeneralCommandRunning(false)
        }
    }

    private func runManualLightingCommand(
        _ action: @escaping @Sendable () async throws -> Void,
        onFailure: (@MainActor () -> Void)? = nil
    ) {
        guard !isCommandRunning, isConnected else {
            return
        }
        setGeneralCommandRunning(true)
        Task {
            do {
                try await action()
                await lightingAutomation.noteManualOverride()
                recordOperation(L("手动前光"), L("指令已发送，自动化暂停到下个时段"))
            } catch {
                onFailure?()
                errorMessage = L("操作未完成，部分设置可能已生效。")
            }
            setGeneralCommandRunning(false)
        }
    }

    private func setGeneralCommandRunning(_ running: Bool) {
        generalCommandRunning = running
        updateCommandRunning()
    }

    private func updateCommandRunning() {
        isCommandRunning = generalCommandRunning
            || lightingCommandSession.isBusy
        flushDisplaySliders()
    }

    private func flushDisplaySliders() {
        guard !isCommandRunning, isConnected, !isShuttingDown, !isSystemSleeping,
              let command = displaySliderQueue.next() else { return }
        switch command {
        case let .threshold(value): sendThreshold(value)
        case let .speed(value): sendSpeed(value)
        }
    }

    private func observeController() async {
        for await state in controller.events {
            let wasConnected = isConnected
            let wasAutomationConnected =
                isConnected && frontLightAvailable
            let resetGeneration: UInt64?
            switch state {
            case .connecting, .disconnected, .unsupported, .failed:
                displaySliderQueue.removeAll()
                resetGeneration = lightingCommandSession
                    .beginConnectionReset()
                connectionState = state
                updateCommandRunning()
                lightingVerified = false
            case .connected:
                resetGeneration = nil
                connectionState = state
                lightingCommandSession.connectionDidBecomeAvailable()
            }
            if let resetGeneration {
                await resetLightingCommands(to: resetGeneration)
            }
            if case let .connected(_, deviceState) = state {
                if !lightingCommandSession.hasPendingCommand(
                    for: .brightness
                ) {
                    brightnessDraft = deviceState.brightness
                }
                if !lightingCommandSession.hasPendingCommand(
                    for: .temperature
                ) {
                    temperatureDraft = deviceState.temperature
                }
                if !wasConnected {
                    reloadDitheringState()
                    reloadEnhancementState()
                    recordOperation(L("控制连接"), L("已连接"))
                    if let app = NSWorkspace.shared.frontmostApplication { handleActiveApplicationChanged(app) }
                }
            }
            let isAutomationConnected =
                isConnected && frontLightAvailable
            if isAutomationConnected != wasAutomationConnected {
                await lightingAutomation.connectionChanged(
                    isConnected: isAutomationConnected
                )
            }
            if case .failed = state {
                recordOperation(L("控制连接"), L("连接中断，正在自动重试"), failed: true)
                startConnectionLoop()
            }
        }
    }

    private func observeAutomation() async {
        for await status in lightingAutomation.events {
            if status.isApplied && !automationStatus.isApplied {
                recordOperation(L("前光自动化"), "\(status.activeRule?.name ?? L("规则"))：\(lightingVerified ? L("设备已确认") : L("指令已发送，未确认"))")
            } else if let failure = status.failureMessage, failure != automationStatus.failureMessage {
                recordOperation(L("前光自动化"), failure, failed: true)
            }
            automationStatus = status
            if !status.isPaused { pauseDescription = nil }
        }
    }

    private func observeLightingCommands() async {
        for await event in lightingCommandCoordinator.events {
            let effect = lightingCommandSession.handle(event)
            updateCommandRunning()
            switch effect {
            case let .succeeded(command):
                await lightingAutomation.noteManualOverride()
                applyCompletedLightingDraft(command)
            case let .failed(command):
                rollbackLightingDraft(command.control)
                errorMessage = L("操作未完成，部分设置可能已生效。")
            case .ignored, .activityChanged:
                break
            }
        }
    }

    private func handleLightingSubmission(
        accepted: Bool,
        submission: LightingCommandSubmission
    ) async {
        guard !accepted else { return }
        lightingCommandSession.submissionRejected(submission)
        updateCommandRunning()
    }

    private func resetLightingCommands(to generation: UInt64) async {
        await lightingCommandCoordinator.reset(to: generation)
        let active = await lightingCommandCoordinator.hasActiveWork()
        _ = lightingCommandSession.handle(
            .activityChanged(active, generation: generation)
        )
        updateCommandRunning()
    }

    private func applyCompletedLightingDraft(_ command: LightingCommand) {
        switch command.control {
        case .brightness:
            brightnessDraft = command.value
        case .temperature:
            temperatureDraft = command.value
        }
    }

    private func rollbackLightingDraft(_ control: LightingControl) {
        switch control {
        case .brightness:
            brightnessDraft = deviceState?.brightness ?? brightnessDraft
        case .temperature:
            temperatureDraft = deviceState?.temperature ?? temperatureDraft
        }
    }

    private func observeSerialDevices() async {
        for await paths in monitor.devices {
            if let path = paths.first {
                if activeSerialPath != path || !isConnected {
                    let changed = activeSerialPath != path
                    activeSerialPath = path
                    startConnectionLoop(force: changed)
                }
            } else {
                activeSerialPath = nil
                connectionRevision += 1
                let previous = reconnectTask
                previous?.cancel()
                reconnectTask = nil
                await previous?.value
                await controller.disconnect()
            }
        }
    }

    private func configureAutoRefresh() {
        Task {
            if settings.autoRefreshEnabled && !allControlsPaused && !isSystemSleeping {
                await autoRefresh.start(
                    intervalSeconds: settings.autoRefreshIntervalSeconds
                )
            } else {
                await autoRefresh.stop()
            }
        }
    }

    private func configureLightingAutomation(applyImmediately: Bool) {
        let settings = automationSettings
        let connected = isConnected && frontLightAvailable
        Task {
            await lightingAutomation.setSuspended(allControlsPaused || isSystemSleeping)
            await lightingAutomation.update(
                settings: settings,
                isConnected: connected,
                applyImmediately: applyImmediately
            )
        }
    }

    private func configureSystemObservers() {
        NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        paperlikeRefreshRate = displayDriver.findPaperlikeRefreshRate()
        displayConnected = NSScreen.screens.contains { $0.localizedName.localizedCaseInsensitiveContains("paperlike") }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.paperlikeRefreshRate = self.displayDriver.findPaperlikeRefreshRate()
                self.displayConnected = NSScreen.screens.contains { $0.localizedName.localizedCaseInsensitiveContains("paperlike") }
                self.reloadDitheringState()
                self.reloadEnhancementState()
                if !self.allControlsPaused && !self.isSystemSleeping { self.applyCalibration(reportFailure: false) }
            }
            .store(in: &cancellables)
        let timeNotifications = [
            Notification.Name.NSSystemClockDidChange,
            Notification.Name.NSSystemTimeZoneDidChange,
            Notification.Name.NSCalendarDayChanged
        ]
        Publishers.MergeMany(
            timeNotifications.map {
                NotificationCenter.default.publisher(for: $0)
            }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.lightingAutomation.refreshNow(forceApply: true)
            }
        }
        .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isSystemSleeping = false
                self.startConnectionLoop(force: true)
                self.configureAutoRefresh()
                self.configureLightingAutomation(applyImmediately: false)
                if !self.allControlsPaused && !self.touchWasPaused { self.touchMapping.start() }
                if !self.allControlsPaused { self.applyCalibration(reportFailure: false) }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isSystemSleeping = true
                self.reconnectTask?.cancel()
                self.appAdaptationTask?.cancel()
                self.touchMapping.pause()
                self.calibrationTask?.cancel()
                do { try self.displayDriver.restoreDisplayCalibration() }
                catch { self.recordOperation(L("睡眠前画面恢复"), L("恢复未完成，原值备份仍保留"), failed: true) }
                self.configureAutoRefresh()
                self.configureLightingAutomation(applyImmediately: false)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self.handleActiveApplicationChanged(app)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.touchMapping.refresh()
                }
            }
            .store(in: &cancellables)
    }

    private func handleActiveApplicationChanged(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }
        appAdaptationTask?.cancel()
        guard settings.isAppAdaptationEnabled, !allControlsPaused, !isSystemSleeping else { return }
        appAdaptationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                while self.isCommandRunning {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard self.isConnected, self.settings.isAppAdaptationEnabled,
                      !self.allControlsPaused, !self.isSystemSleeping else { return }
                let rule = self.settings.rules.first { $0.bundleIdentifier == bundleID && $0.isEnabled }
                let target = rule.map { (mode: $0.mode, threshold: $0.threshold) } ?? self.lastManualState
                guard let target else { return }
                if rule != nil, self.lastManualState == nil, let state = self.deviceState {
                    self.lastManualState = (state.mode, state.threshold)
                }
                self.setGeneralCommandRunning(true)
                defer { self.setGeneralCommandRunning(false) }
                try await self.controller.setMode(target.mode)
                try Task.checkCancellation()
                try await self.controller.setThreshold(target.threshold)
                try Task.checkCancellation()
                self.lastAppliedApp = rule == nil ? nil : bundleID
                if rule == nil { self.lastManualState = nil }
                self.recordOperation(L("应用自适应"), rule?.appName ?? L("已恢复手动设置"))
            } catch is CancellationError {
                // The latest foreground application owns the next operation.
            } catch {
                guard !Task.isCancelled else { return }
                self?.recordOperation(L("应用自适应"), L("未完成，未标记为已应用"), failed: true)
            }
        }
    }

    private func cancelAppAdaptationForManualChange() {
        guard !isCommandRunning else { return }
        appAdaptationTask?.cancel()
        lastAppliedApp = nil
        lastManualState = nil
    }

    private func startConnectionLoop(force: Bool = false) {
        guard let path = activeSerialPath, !isShuttingDown, !isSystemSleeping else { return }
        guard force || (reconnectTask == nil && !isConnected) else { return }
        let previous = reconnectTask
        previous?.cancel()
        connectionRevision += 1
        let revision = connectionRevision
        reconnectTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { if self.connectionRevision == revision { self.reconnectTask = nil } }
            var delay = 1
            while !Task.isCancelled && self.connectionRevision == revision && self.activeSerialPath == path {
                do {
                    try await self.controller.connect(path: path)
                    return
                } catch PaperlikeDeviceError.unsupported {
                    self.recordOperation(L("控制连接"), L("型号不支持，已停止自动重试"), failed: true)
                    return
                } catch {
                    if Task.isCancelled { return }
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    delay = min(30, delay * 2)
                }
            }
        }
    }

    private func performAutomaticRefresh() async throws {
        guard !allControlsPaused, !isSystemSleeping, !isCommandRunning, isConnected else { return }
        setGeneralCommandRunning(true)
        defer { setGeneralCommandRunning(false) }
        try await controller.refresh()
    }

    func recordOperation(_ title: String, _ detail: String, failed: Bool = false) {
        recentOperations.insert(OperationRecord(title: title, detail: detail, failed: failed), at: 0)
        if recentOperations.count > 50 { recentOperations.removeLast(recentOperations.count - 50) }
    }

    func setAllControlsPaused(_ paused: Bool) {
        allControlsPaused = paused
        UserDefaults.standard.set(paused, forKey: "PaperLikeNative.AllControlsPaused")
        appAdaptationTask?.cancel()
        if paused {
            touchMapping.pause()
        } else if !touchWasPaused && !isSystemSleeping {
            touchMapping.start()
        }
        if !paused { applyCalibration() }
        configureAutoRefresh()
        Task {
            await lightingAutomation.setSuspended(allControlsPaused || isSystemSleeping)
            if !allControlsPaused, let app = NSWorkspace.shared.frontmostApplication { handleActiveApplicationChanged(app) }
        }
        recordOperation(L("自动控制"), paused ? L("已暂停，仍可手动调节") : L("已恢复原来的启用项"))
    }

    func resumeImportedConfiguration() { setAllControlsPaused(false) }

    func pauseLighting(minutes: Int? = nil, untilTomorrow: Bool = false) {
        let end: Date
        if untilTomorrow {
            end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date().addingTimeInterval(86_400)
            pauseDescription = L("暂停到明天")
        } else if let minutes {
            end = Date().addingTimeInterval(Double(minutes * 60))
            pauseDescription = L("暂停到 \(end.formatted(.dateTime.hour().minute().locale(AppLanguage.current.locale)))")
        } else {
            pauseAutomationUntilNextBoundary()
            pauseDescription = L("暂停到下个时段")
            return
        }
        Task { await lightingAutomation.pause(until: end) }
    }

    func resumeLighting() {
        pauseDescription = nil
        Task { await lightingAutomation.resume() }
    }

    private func configureTouchMapping() {
        touchMapping.$status
            .sink { [weak self] in self?.touchStatus = $0 }
            .store(in: &cancellables)
        touchMapping.$latestFrame
            .sink { [weak self] in self?.touchLatestFrame = $0 }
            .store(in: &cancellables)
        touchMapping.$settings
            .sink { [weak self] in self?.touchSettings = $0 }
            .store(in: &cancellables)
        touchMapping.$availableDisplays
            .sink { [weak self] in self?.touchAvailableDisplays = $0 }
            .store(in: &cancellables)
        touchMapping.$isTesting
            .sink { [weak self] in self?.touchIsTesting = $0 }
            .store(in: &cancellables)
        touchMapping.$isTouchDeviceConnected
            .sink { [weak self] in self?.touchIsTouchDeviceConnected = $0 }
            .store(in: &cancellables)
        touchMapping.$isAccessibilityTrusted
            .sink { [weak self] in self?.touchIsAccessibilityTrusted = $0 }
            .store(in: &cancellables)
        touchMapping.$targetDisplay
            .sink { [weak self] in self?.touchTargetDisplay = $0 }
            .store(in: &cancellables)
        touchMapping.touchDiagnosticsSubject
            .removeDuplicates()
            .sink { [weak self] in self?.touchDiagnosticsModel.snapshot = $0 }
            .store(in: &cancellables)
        if !allControlsPaused { touchMapping.start() }
    }

    func setTouchDiagnosticsVisible(_ visible: Bool) {
        touchMapping.setDiagnosticsEnabled(visible)
        if visible { touchDiagnosticsModel.snapshot = touchMapping.touchDiagnostics }
    }

    private func applyAutomatedLighting(
        _ configuration: LightingConfiguration
    ) async throws {
        guard !allControlsPaused, !isSystemSleeping, !isCommandRunning, isConnected else {
            throw PaperlikeDeviceError.busy
        }
        guard frontLightAvailable else {
            throw PaperlikeDeviceError.unsupportedFeature(name: L("前光"))
        }
        setGeneralCommandRunning(true)
        defer { setGeneralCommandRunning(false) }

        lightingVerified = false
        try await controller.setFrontLightMode(configuration.frontLightMode)
        guard !allControlsPaused, !isSystemSleeping else { throw CancellationError() }
        if configuration.frontLightMode != 0 {
            try await controller.setBrightness(configuration.brightness)
            guard !allControlsPaused, !isSystemSleeping else { throw CancellationError() }
            try await controller.setTemperature(configuration.temperature)
        }
        try await verifyLighting(configuration)
    }

    private func verifyLighting(_ expected: LightingConfiguration) async throws {
        do {
            let actual = try await controller.readLightingConfiguration()
            guard actual.frontLightMode == expected.frontLightMode,
                  expected.frontLightMode == 0 || actual == expected else {
                throw PaperlikeDeviceError.verificationFailed
            }
            lightingVerified = true
        } catch PaperlikeDeviceError.timedOut {
            lightingVerified = false
            recordOperation(L("前光确认"), L("已发送，但读回超时；未宣称设备已确认"))
        }
    }

    var automationSummary: String {
        if allControlsPaused { return L("全部自动控制已暂停") }
        if let failure = automationStatus.failureMessage { return failure }
        if !automationSettings.isEnabled { return L("自动化已关闭") }
        if automationStatus.isPaused { return pauseDescription ?? L("已暂停到下个时段") }
        if !isConnected { return L("等待显示器连接") }
        guard let rule = automationStatus.activeRule else { return L("当前没有匹配规则") }
        return automationStatus.isApplied
            ? "\(lightingVerified ? L("设备已确认") : L("指令已发送，未确认"))：\(rule.name)"
            : L("等待执行：\(rule.name)")
    }

    func retryAutomation() {
        Task { await lightingAutomation.refreshNow(forceApply: true) }
    }

    private func hotKeyDefinitions(in settings: AppSettings) -> [HotKeyAction: HotKeyDefinition] {
        var definitions: [HotKeyAction: HotKeyDefinition] = [:]
        if let value = settings.modeHotKey {
            definitions[.cycleMode] = value
        }
        if let value = settings.refreshHotKey {
            definitions[.refresh] = value
        }
        if let value = settings.thresholdUpHotKey {
            definitions[.thresholdUp] = value
        }
        if let value = settings.thresholdDownHotKey {
            definitions[.thresholdDown] = value
        }

        return definitions
    }

    private func refreshHotKeyRegistrationStatus() {
        hotKeyRegistrationIssues = hotKeys.registrationIssues(comparedTo: hotKeyDefinitions(in: savedSettings))
    }

    func retrySavedHotKeys() {
        defer { refreshHotKeyRegistrationStatus() }
        do { try configureHotKeys(using: savedSettings) }
        catch { errorMessage = L("快捷键重试未完成：\(error.localizedDescription)") }
    }

    private func configureHotKeys(using settings: AppSettings) throws {
        defer { refreshHotKeyRegistrationStatus() }
        try hotKeys.apply(
            definitions: hotKeyDefinitions(in: settings),
            handlers: [
                .cycleMode: { [weak self] in self?.cycleMode() },
                .refresh: { [weak self] in self?.performRefresh() },
                .thresholdUp: { [weak self] in
                    self?.adjustThreshold(by: 1)
                },
                .thresholdDown: { [weak self] in
                    self?.adjustThreshold(by: -1)
                }
            ]
        )
    }

    func saveCurrentPreset() {
        guard let state = deviceState else {
            errorMessage = L("请先连接显示器。")
            return
        }
        let lighting = state.frontLightAvailable ? LightingConfiguration(frontLightMode: state.frontLightMode,
            brightness: state.brightness, temperature: state.temperature) : nil
        let value = DisplayPreset(id: presets.first?.id ?? UUID(), name: L("我的场景"), mode: state.mode, threshold: state.threshold,
            speed: state.speed, lighting: lighting)
        let updated = DisplayPreset.updatingMyScene(existing: presets, with: value)
        do {
            try PresetStore.save(updated)
            presets = updated
        } catch { errorMessage = error.localizedDescription }
    }

    func deletePreset(_ id: UUID) {
        let remaining = presets.filter { $0.id != id }
        do {
            try PresetStore.save(remaining)
            presets = remaining
        } catch { errorMessage = error.localizedDescription }
    }

    func applyPreset(_ preset: DisplayPreset) {
        guard preset.isValid, isConnected, !isCommandRunning else { return }
        cancelAppAdaptationForManualChange()
        setGeneralCommandRunning(true)
        Task {
            defer { setGeneralCommandRunning(false) }
            do {
                // Reserve manual intent before the first write.
                await lightingAutomation.noteManualOverride()
                try await controller.setMode(preset.mode)
                try await controller.setThreshold(preset.threshold)
                if let speed = preset.speed { try await controller.setSpeed(speed) }
                if frontLightAvailable, let light = preset.lighting {
                    lightingVerified = false
                    try await controller.setFrontLightMode(light.frontLightMode)
                    if light.frontLightMode != 0 {
                        try await controller.setBrightness(light.brightness)
                        try await controller.setTemperature(light.temperature)
                    }
                    try await verifyLighting(light)
                }
                recordOperation(L("场景"), L("\(preset.name)：指令已发送"))
            } catch {
                errorMessage = L("场景未完整应用，部分设置可能已生效。")
                recordOperation(L("场景"), L("\(preset.name)：未完整应用"), failed: true)
            }
        }
    }

    func configurationBackup() -> ConfigurationBackup {
        ConfigurationBackup(
            settings: settings,
            automation: automationSettings,
            touch: touchSettings,
            presets: presets,
            frontLightPresets: frontLightPresets
        )
    }

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = L("PaperLike-配置.json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try configurationBackup().encoded().write(to: url, options: .atomic)
            recordOperation(L("配置备份"), L("已导出，不包含系统授权"))
        } catch { errorMessage = L("导出失败：\(error.localizedDescription)") }
    }

    @Published var recoveryWizardPresented = false
    @Published private(set) var configurationRecoveryNeeded = false
    @Published private(set) var recoveryArchiveExported = false
    @Published private(set) var recoveryImportCompleted = false

    func exportRawConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = L("PaperLike-原始配置备份.plist")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RawConfigurationArchive.encoded().write(to: url, options: .atomic)
            recoveryArchiveExported = true
            recordOperation(L("原始配置备份"), L("已导出，包含保留的损坏数据"))
        } catch { errorMessage = L("导出失败：\(error.localizedDescription)") }
    }

    func previewConfigurationImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try FileHandle(forReadingFrom: url)
            recoveryImportCompleted = false
            defer { try? file.close() }
            let data = try file.read(upToCount: 1_048_577) ?? Data()
            pendingImport = try ConfigurationBackup.decode(data)
        } catch { errorMessage = L("无法导入：\(error.localizedDescription)") }
    }

    func confirmConfigurationImport() {
        defer { refreshHotKeyRegistrationStatus() }
        guard let incoming = pendingImport, !isCommandRunning else { return }
        let previous = configurationBackup()
        let wasPaused = allControlsPaused
        let incomingFrontLightPresets = incoming.frontLightPresets ?? frontLightPresets
        do {
            _ = try incoming.encoded()
            try ConfigurationImportTransaction.perform(wasPaused: wasPaused, setPaused: setAllControlsPaused) {
            try configureHotKeys(using: incoming.settings)
            try settingsStore.save(incoming.settings)
            try automationSettingsStore.save(incoming.automation)
            try PresetStore.save(incoming.presets)
            try FrontLightPresetStore.save(incomingFrontLightPresets)
            guard touchMapping.applySettings(incoming.touch) else { throw ConfigurationBackupError.invalidValues }
            settings = incoming.settings
            savedSettings = incoming.settings
            automationSettings = incoming.automation
            savedAutomationSettings = incoming.automation
            presets = incoming.presets
            frontLightPresets = incomingFrontLightPresets
            synchronizeCalibrationDrafts()
            configureLightingAutomation(applyImmediately: false)
            pendingImport = nil
            appRuleDraft.discard()
            automationRuleDraft.discard()
            recordOperation(L("配置导入"), L("已导入；自动控制暂停，确认设置后可恢复"))
            recoveryImportCompleted = true
            configurationRecoveryNeeded = false
            } rollback: {
            var rollbackError: Error?
            let restores: [() throws -> Void] = [
                { try self.settingsStore.save(previous.settings) },
                { try self.automationSettingsStore.save(previous.automation) },
                { try PresetStore.save(previous.presets) },
                { try FrontLightPresetStore.save(previous.frontLightPresets ?? []) },
                { try self.configureHotKeys(using: previous.settings) }
            ]
            for restore in restores {
                do { try restore() } catch { rollbackError = error }
            }
            guard touchMapping.applySettings(previous.touch) else { throw ConfigurationBackupError.invalidValues }
            settings = previous.settings
            savedSettings = previous.settings
            automationSettings = previous.automation
            savedAutomationSettings = previous.automation
            presets = previous.presets
            frontLightPresets = previous.frontLightPresets ?? []
            synchronizeCalibrationDrafts()
            configureLightingAutomation(applyImmediately: false)
            if let rollbackError { throw rollbackError }
            }
        } catch {
            errorMessage = L("导入未完成：\(error.localizedDescription)")
            recordOperation(L("配置导入"), L("未完成，已尝试恢复原配置与启用状态"), failed: true)
        }
    }

    private func synchronizeCalibrationDrafts() {
        saturation = settings.saturationValue
        isGrayscaleEnabled = settings.isGrayscaleEnabled
        grayscaleRedThreshold = settings.redThreshold
        grayscaleGreenThreshold = settings.greenThreshold
        grayscaleBlueThreshold = settings.blueThreshold
        grayscaleContrast = settings.contrastSlope
    }

    @Published private(set) var displayConnected = false

    private var settingsWindow: NSWindow?
    private var settingsWindowObserver: NSObjectProtocol?

    public func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsWindowLayout.initialSize.width, height: SettingsWindowLayout.initialSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L("设置")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.contentMinSize = SettingsWindowLayout.minimumSize
        window.contentViewController = NSHostingController(rootView: SettingsView(model: self))
        window.setFrameAutosaveName("PaperLikeNative.Settings")
        if !window.setFrameUsingName("PaperLikeNative.Settings") { window.center() }
        window.isReleasedWhenClosed = false

        settingsWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settingsWindow = nil
                if let token = self?.settingsWindowObserver {
                    NotificationCenter.default.removeObserver(token)
                    self?.settingsWindowObserver = nil
                }
            }
        }

        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reloadAccessibilitySettings() {
        systemReduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        systemIncreaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    func setSystemReduceTransparency(_ enabled: Bool) {
        let script = "tell application \"System Events\" to set reduce transparency of accessibility preferences to \(enabled)"
        updateSystemSetting(script)
    }

    func setSystemIncreaseContrast(_ enabled: Bool) {
        let script = "tell application \"System Events\" to set increase contrast of accessibility preferences to \(enabled)"
        updateSystemSetting(script)
    }

    private func updateSystemSetting(_ source: String) {
        guard !isSystemSettingsUpdating else { return }
        isSystemSettingsUpdating = true
        systemSettingsTask = Task {
            defer { isSystemSettingsUpdating = false; systemSettingsTask = nil; reloadAccessibilitySettings() }
            do { try await AppleScriptRunner().run(source) }
            catch is CancellationError { }
            catch { errorMessage = L("无法修改系统辅助功能设置，请检查系统设置中的自动化权限：\(error.localizedDescription)") }
        }
    }
}

extension AppModel {
    public func mockConnectedForPreview() {
        let profile = PaperlikeDeviceProfile(mcuVersion: 0x30, familyIdentifier: 0x01)!
        let deviceState = DeviceState(
            profile: profile,
            mode: .text,
            threshold: 5,
            speed: 3,
            frontLightMode: 3,
            brightness: 50,
            temperature: 50
        )
        self.connectionState = .connected(name: "PaperLike Mock Device", state: deviceState)
        self.brightnessDraft = 50
        self.temperatureDraft = 50
    }
}
