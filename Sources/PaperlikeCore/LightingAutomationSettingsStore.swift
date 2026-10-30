import Foundation

public final class LightingAutomationSettingsStore: @unchecked Sendable {
    private static let key = "PaperLikeNative.LightingAutomationSettings"
    public static let corruptBackupKey = "PaperLikeNative.LightingAutomationSettings.CorruptBackup"

    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    public private(set) var recoveredCorruptData = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> LightingAutomationSettings {
        guard let raw = defaults.object(forKey: Self.key) else { return LightingAutomationSettings() }
        guard let data = raw as? Data,
              let settings = try? decoder.decode(LightingAutomationSettings.self, from: data) else {
            recoveredCorruptData = true
            if defaults.object(forKey: Self.corruptBackupKey) == nil {
                defaults.set(raw, forKey: Self.corruptBackupKey)
            }
            return LightingAutomationSettings()
        }
        return settings
    }

    public func save(_ settings: LightingAutomationSettings) throws {
        try settings.validate()
        defaults.set(try SettingsValidation.encodeSection(settings), forKey: Self.key)
    }
}
