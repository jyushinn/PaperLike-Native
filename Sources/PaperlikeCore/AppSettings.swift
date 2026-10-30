import Foundation

public struct HotKeyDefinition: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var autoRefreshEnabled: Bool
    public var autoRefreshIntervalSeconds: Int
    public var modeHotKey: HotKeyDefinition?
    public var refreshHotKey: HotKeyDefinition?
    public var thresholdUpHotKey: HotKeyDefinition?
    public var thresholdDownHotKey: HotKeyDefinition?
    public var appAdaptationEnabled: Bool?
    public var appRules: [AppAdaptationRule]?
    public var saturation: Double?

    // Advanced Grayscale Settings
    public var grayscaleRedThreshold: Double?
    public var grayscaleGreenThreshold: Double?
    public var grayscaleBlueThreshold: Double?
    public var grayscaleContrast: Double?
    public var grayscaleEnabled: Bool?

    public var isAppAdaptationEnabled: Bool {
        get { appAdaptationEnabled ?? false }
        set { appAdaptationEnabled = newValue }
    }

    public var rules: [AppAdaptationRule] {
        get { appRules ?? [] }
        set { appRules = newValue }
    }

    public var saturationValue: Double {
        get { saturation ?? 0.5 }
        set { saturation = newValue }
    }

    public var isGrayscaleEnabled: Bool {
        get { grayscaleEnabled ?? false }
        set { grayscaleEnabled = newValue }
    }

    public var redThreshold: Double {
        get { grayscaleRedThreshold ?? 0.5 }
        set { grayscaleRedThreshold = newValue }
    }

    public var greenThreshold: Double {
        get { grayscaleGreenThreshold ?? 0.5 }
        set { grayscaleGreenThreshold = newValue }
    }

    public var blueThreshold: Double {
        get { grayscaleBlueThreshold ?? 0.5 }
        set { grayscaleBlueThreshold = newValue }
    }

    public var contrastSlope: Double {
        get { grayscaleContrast ?? 6.0 }
        set { grayscaleContrast = newValue }
    }

    public init(
        autoRefreshEnabled: Bool = false,
        autoRefreshIntervalSeconds: Int = 30,
        modeHotKey: HotKeyDefinition? = nil,
        refreshHotKey: HotKeyDefinition? = nil,
        thresholdUpHotKey: HotKeyDefinition? = nil,
        thresholdDownHotKey: HotKeyDefinition? = nil,
        appAdaptationEnabled: Bool = false,
        appRules: [AppAdaptationRule] = [],
        saturation: Double = 0.5,
        isGrayscaleEnabled: Bool = false,
        redThreshold: Double = 0.5,
        greenThreshold: Double = 0.5,
        blueThreshold: Double = 0.5,
        contrastSlope: Double = 6.0
    ) {
        self.autoRefreshEnabled = autoRefreshEnabled
        self.autoRefreshIntervalSeconds = autoRefreshIntervalSeconds
        self.modeHotKey = modeHotKey
        self.refreshHotKey = refreshHotKey
        self.thresholdUpHotKey = thresholdUpHotKey
        self.thresholdDownHotKey = thresholdDownHotKey
        self.appAdaptationEnabled = appAdaptationEnabled
        self.appRules = appRules
        self.saturation = saturation
        self.grayscaleEnabled = isGrayscaleEnabled
        self.grayscaleRedThreshold = redThreshold
        self.grayscaleGreenThreshold = greenThreshold
        self.grayscaleBlueThreshold = blueThreshold
        self.grayscaleContrast = contrastSlope
    }
}

public final class AppSettingsStore: @unchecked Sendable {
    private static let key = "PaperLikeNative.AppSettings"
    public static let corruptBackupKey = "PaperLikeNative.AppSettings.CorruptBackup"

    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    public private(set) var recoveredCorruptData = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard let raw = defaults.object(forKey: Self.key) else { return AppSettings() }
        guard let data = raw as? Data,
              let settings = try? decoder.decode(AppSettings.self, from: data) else {
            recoveredCorruptData = true
            if defaults.object(forKey: Self.corruptBackupKey) == nil {
                defaults.set(raw, forKey: Self.corruptBackupKey)
            }
            return AppSettings()
        }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        try settings.validate()
        let data = try SettingsValidation.encodeSection(settings)
        defaults.set(data, forKey: Self.key)
    }
}

public enum SettingsValidation {
    // Five compact JSON sections fit within the 1 MiB backup, including envelope keys.
    public static let maximumSectionBytes = 192 * 1024

    public static func encodeSection<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumSectionBytes else {
            throw SettingsValidationError.invalid("配置内容过多，请减少规则或预设后重试。")
        }
        return data
    }

    public static let maximumRules = 200
    public static let maximumNameLength = 120
    public static let maximumNameUTF8Bytes = 480

    public static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= maximumNameLength else {
            throw SettingsValidationError.invalid("名称须为 1–120 个字符。")
        }
        guard name.utf8.count <= maximumNameUTF8Bytes else {
            throw SettingsValidationError.invalid("名称包含过多组合字符，请缩短名称。")
        }
    }

    public static func appRuleIssues(_ rules: [AppAdaptationRule]) -> [String] {
        var issues: [String] = []
        if rules.count > maximumRules { issues.append("应用规则还需删除 \(rules.count - maximumRules) 条（最多 200 条）。") }
        let duplicateIDs = rules.count - Set(rules.map(\.id)).count
        let duplicateBundles = rules.count - Set(rules.map(\.bundleIdentifier)).count
        if duplicateIDs > 0 || duplicateBundles > 0 { issues.append("存在重复应用规则，请删除重复项。") }
        let invalidNames = rules.filter { (try? validateName($0.appName)) == nil }.count
        if invalidNames > 0 { issues.append("还有 \(invalidNames) 条应用名称无效，请缩短名称或补齐空名称。") }
        let invalidValues = rules.filter {
            $0.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.bundleIdentifier.count > 255 || $0.bundleIdentifier.utf8.count > 1_020 || !(1...9).contains($0.threshold)
        }.count
        if invalidValues > 0 { issues.append("还有 \(invalidValues) 条规则的 Bundle ID 或对比度无效（请缩短或修正 Bundle ID，对比度须为 1–9）。") }
        return issues
    }

    public static func automationRuleIssues(_ rules: [LightingScheduleRule]) -> [String] {
        var issues: [String] = []
        if rules.count > maximumRules { issues.append("前光规则还需删除 \(rules.count - maximumRules) 条（最多 200 条）。") }
        if Set(rules.map(\.id)).count != rules.count { issues.append("存在重复前光规则，请删除重复项。") }
        let invalidNames = rules.filter { (try? validateName($0.name)) == nil }.count
        if invalidNames > 0 { issues.append("还有 \(invalidNames) 条前光名称无效，请缩短名称或补齐空名称。") }
        let missingWeekdays = rules.filter { $0.weekdays.isEmpty }.count
        if missingWeekdays > 0 { issues.append("还有 \(missingWeekdays) 条时间规则须至少选择一天。") }
        return issues
    }

    public static func validateAppRules(_ rules: [AppAdaptationRule]) throws {
        let issues = appRuleIssues(rules)
        if !issues.isEmpty { throw SettingsValidationError.invalid(issues.joined(separator: " ")) }
    }

}

public enum SettingsValidationError: Error, Equatable, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): message } }
}

extension AppSettings {
    public func validate() throws {
        let colors = [saturationValue, redThreshold, greenThreshold, blueThreshold]
        let keys = [modeHotKey, refreshHotKey, thresholdUpHotKey, thresholdDownHotKey].compactMap { $0 }
        guard (30...600).contains(autoRefreshIntervalSeconds),
              colors.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              contrastSlope.isFinite && (1...20).contains(contrastSlope),
              Set(keys).count == keys.count,
              keys.allSatisfy({ $0.keyCode <= 127 && $0.modifiers != 0 && $0.modifiers & ~UInt32(0x1B00) == 0 }) else {
            throw SettingsValidationError.invalid("设置包含无效参数或重复快捷键。")
        }
        try SettingsValidation.validateAppRules(rules)
    }
}

extension LightingAutomationSettings {
    public func validate() throws {
        let issues = SettingsValidation.automationRuleIssues(rules)
        if !issues.isEmpty { throw SettingsValidationError.invalid(issues.joined(separator: " ")) }
    }
}
