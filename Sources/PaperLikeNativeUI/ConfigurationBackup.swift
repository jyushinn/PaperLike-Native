import Foundation
import PaperlikeCore
import PaperlikeTouch

/// Imports remain paused for review. Restore the previous run state only after a successful rollback.
public enum ConfigurationImportTransaction {
    public static func perform(
        wasPaused: Bool,
        setPaused: (Bool) -> Void,
        replace: () throws -> Void,
        rollback: () throws -> Void
    ) throws {
        setPaused(true)
        do {
            try replace()
        } catch {
            do { try rollback() }
            catch let rollbackError {
                throw ConfigurationImportRollbackError(original: error, rollback: rollbackError)
            }
            setPaused(wasPaused)
            throw error
        }
    }
}

private struct ConfigurationImportRollbackError: LocalizedError {
    let original: Error
    let rollback: Error
    var errorDescription: String? {
        "导入失败：\(original.localizedDescription)；恢复也未完成：\(rollback.localizedDescription)"
    }
}

public struct DisplayPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var mode: DisplayMode
    public var threshold: Int
    public var speed: Int?
    public var lighting: LightingConfiguration?

    public init(id: UUID = UUID(), name: String, mode: DisplayMode, threshold: Int,
                speed: Int? = nil, lighting: LightingConfiguration? = nil) {
        self.id = id
        self.name = name
        self.mode = mode
        self.threshold = threshold
        self.speed = speed
        self.lighting = lighting
    }

    public static let builtIns = [
        DisplayPreset(name: "我的场景", mode: .text, threshold: 5, speed: 2)
    ]

    public static func updatingMyScene(existing: [DisplayPreset], with preset: DisplayPreset) -> [DisplayPreset] {
        let scene = DisplayPreset(
            id: existing.first?.id ?? preset.id,
            name: "我的场景",
            mode: preset.mode,
            threshold: preset.threshold,
            speed: preset.speed,
            lighting: preset.lighting
        )
        guard !existing.isEmpty else { return [scene] }
        var updated = existing
        updated[0] = scene
        return updated
    }

    var isValid: Bool {
        (try? SettingsValidation.validateName(name)) != nil
            && (1...9).contains(threshold) && (speed == nil || (1...5).contains(speed!))
    }
}

enum PresetStore {
    static let key = "PaperLikeNative.DisplayPresets"
    static let corruptBackupKey = key + ".CorruptBackup"
    static func load(defaults: UserDefaults = .standard, onCorruption: () -> Void = {}) -> [DisplayPreset] {
        guard let raw = defaults.object(forKey: key) else { return DisplayPreset.builtIns }
        guard let data = raw as? Data,
              let presets = try? JSONDecoder().decode([DisplayPreset].self, from: data),
              presets.count <= 200, presets.allSatisfy(\.isValid),
              Set(presets.map(\.id)).count == presets.count else {
            if defaults.object(forKey: corruptBackupKey) == nil { defaults.set(raw, forKey: corruptBackupKey) }
            onCorruption()
            return DisplayPreset.builtIns
        }
        return presets
    }
    static func save(_ presets: [DisplayPreset]) throws {
        guard presets.count <= 200, presets.allSatisfy(\.isValid),
              Set(presets.map(\.id)).count == presets.count else { throw ConfigurationBackupError.invalidValues }
        UserDefaults.standard.set(try SettingsValidation.encodeSection(presets), forKey: key)
    }

}

public struct FrontLightPreset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let configuration: LightingConfiguration

    public init(
        id: UUID = UUID(),
        name: String,
        configuration: LightingConfiguration
    ) {
        self.id = id
        self.name = name
        self.configuration = configuration
    }

    var isValid: Bool {
        (try? SettingsValidation.validateName(name)) != nil
    }
}

enum FrontLightPresetStore {
    private static let key = "PaperLikeNative.FrontLightPresets"
    static let corruptBackupKey = key + ".CorruptBackup"

    static func load(defaults: UserDefaults = .standard, onCorruption: () -> Void = {}) -> [FrontLightPreset] {
        guard let raw = defaults.object(forKey: key) else { return [] }
        guard let data = raw as? Data,
              let presets = try? JSONDecoder().decode([FrontLightPreset].self, from: data),
              presets.count <= SettingsValidation.maximumRules, presets.allSatisfy(\.isValid),
              Set(presets.map(\.id)).count == presets.count else {
            if defaults.object(forKey: corruptBackupKey) == nil { defaults.set(raw, forKey: corruptBackupKey) }
            onCorruption()
            return []
        }
        return presets
    }

    static func save(_ presets: [FrontLightPreset]) throws {
        guard presets.count <= SettingsValidation.maximumRules, presets.allSatisfy(\.isValid),
              Set(presets.map(\.id)).count == presets.count else {
            throw ConfigurationBackupError.invalidValues
        }
        UserDefaults.standard.set(try SettingsValidation.encodeSection(presets), forKey: key)
    }
}

struct OperationRecord: Identifiable {
    let id = UUID()
    let date = Date()
    let title: String
    let detail: String
    let failed: Bool
}

public enum ConfigurationBackupError: Error, Equatable, LocalizedError {
    case tooLarge, unsupportedVersion, invalidValues
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "配置文件超过 1 MB，无法导入。"
        case .unsupportedVersion: "不支持此配置版本。"
        case .invalidValues: "配置包含无效参数、重复项目或过多规则，未修改现有设置。"
        }
    }
}

public struct ConfigurationBackup: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { version }
    public let version: Int
    public let settings: AppSettings
    public let automation: LightingAutomationSettings
    public let touch: TouchMappingSettings
    public let presets: [DisplayPreset]
    public let frontLightPresets: [FrontLightPreset]?

    public init(settings: AppSettings, automation: LightingAutomationSettings,
                touch: TouchMappingSettings, presets: [DisplayPreset],
                frontLightPresets: [FrontLightPreset]? = nil) {
        version = 1
        self.settings = settings
        self.automation = automation
        self.touch = touch
        self.presets = presets
        self.frontLightPresets = frontLightPresets
    }

    public func impactSummary(comparedTo previous: ConfigurationBackup) -> [String] {
        var changes: [String] = []
        if settings.rules != previous.settings.rules || settings.isAppAdaptationEnabled != previous.settings.isAppAdaptationEnabled {
            changes.append("应用规则：\(previous.settings.rules.count) → \(settings.rules.count) 条（内容或启用状态变化）")
        }
        if automation != previous.automation { changes.append("前光规则：\(previous.automation.rules.count) → \(automation.rules.count) 条（内容或启用状态变化）") }
        let keys = [settings.modeHotKey, settings.refreshHotKey, settings.thresholdUpHotKey, settings.thresholdDownHotKey]
        let previousKeys = [previous.settings.modeHotKey, previous.settings.refreshHotKey, previous.settings.thresholdUpHotKey, previous.settings.thresholdDownHotKey]
        if keys != previousKeys { changes.append("全局快捷键将立即更换") }
        if touch.displaySelection != previous.touch.displaySelection { changes.append("触控目标显示器将更换；恢复自动控制后使用") }
        if touch != previous.touch { changes.append("触控参数将保存，触控保持暂停") }
        if [settings.saturationValue, settings.redThreshold, settings.greenThreshold, settings.blueThreshold, settings.contrastSlope] != [previous.settings.saturationValue, previous.settings.redThreshold, previous.settings.greenThreshold, previous.settings.blueThreshold, previous.settings.contrastSlope] || settings.isGrayscaleEnabled != previous.settings.isGrayscaleEnabled {
            changes.append("画面校准变化；恢复自动控制时应用于显示器")
        }
        if settings.autoRefreshEnabled != previous.settings.autoRefreshEnabled || settings.autoRefreshIntervalSeconds != previous.settings.autoRefreshIntervalSeconds { changes.append("自动清残影设置变化；恢复自动控制后运行") }
        if presets != previous.presets { changes.append("场景：\(previous.presets.count) → \(presets.count) 个；需手动应用场景") }
        if let frontLightPresets, frontLightPresets != previous.frontLightPresets { changes.append("前光预设：\(previous.frontLightPresets?.count ?? 0) → \(frontLightPresets.count) 个") }
        return changes.isEmpty ? ["配置内容相同；导入后自动控制仍会暂停。"] : changes
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 1_048_576 else { throw ConfigurationBackupError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw ConfigurationBackupError.tooLarge }
        // Check raw values before legacy decoders clamp them into valid ranges.
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let root = raw as? [String: Any], root["version"] as? Int == 1 else {
            throw ConfigurationBackupError.unsupportedVersion
        }
        try validateRaw(raw, depth: 0)
        let backup = try JSONDecoder().decode(Self.self, from: data)
        try backup.validate()
        return backup
    }

    public func validate() throws {
        guard version == 1 else { throw ConfigurationBackupError.unsupportedVersion }
        do {
            try settings.validate()
            try automation.validate()
        } catch { throw ConfigurationBackupError.invalidValues }
        guard presets.count <= 200, presets.allSatisfy(\.isValid), Set(presets.map(\.id)).count == presets.count,
              (frontLightPresets?.count ?? 0) <= SettingsValidation.maximumRules,
              frontLightPresets?.allSatisfy(\.isValid) ?? true,
              Set(frontLightPresets?.map(\.id) ?? []).count == (frontLightPresets?.count ?? 0)
        else { throw ConfigurationBackupError.invalidValues }
        _ = try SettingsValidation.encodeSection(settings)
        _ = try SettingsValidation.encodeSection(automation)
        _ = try touch.encodedForStorage()
        _ = try SettingsValidation.encodeSection(presets)
        if let frontLightPresets { _ = try SettingsValidation.encodeSection(frontLightPresets) }
    }

    private static func validateRaw(_ value: Any, depth: Int) throws {
        guard depth <= 32 else { throw ConfigurationBackupError.invalidValues }
        if let object = value as? [String: Any] {
            for (key, item) in object {
                let range: ClosedRange<Double>?
                switch key {
                case "frontLightMode": range = 0...3
                case "brightness", "temperature": range = 0...100
                case "start", "end": range = 0...1439
                case "speed": range = 1...5
                case "threshold": range = 1...9
                case "minX", "maxX", "minY", "maxY": range = 0...65535
                default: range = nil
                }
                if let range, !(item is NSNull) {
                    guard let number = item as? NSNumber, number.doubleValue.isFinite,
                          range.contains(number.doubleValue) else { throw ConfigurationBackupError.invalidValues }
                }
                try validateRaw(item, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for item in array { try validateRaw(item, depth: depth + 1) }
        }
    }
}
