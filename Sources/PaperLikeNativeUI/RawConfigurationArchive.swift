import Foundation

enum RawConfigurationArchive {
    static let keys = ["AppSettings", "LightingAutomationSettings", "TouchMappingSettings", "DisplayPresets", "FrontLightPresets"]

    static func encoded(defaults: UserDefaults = .standard) throws -> Data {
        var entries: [String: Any] = [:]
        for section in keys {
            let key = "PaperLikeNative." + section
            for name in [key, key + ".CorruptBackup"] {
                if let value = defaults.object(forKey: name) { entries[name] = value }
            }
        }
        // Preserve invalid types and undecodable bytes; this archive is not an importable configuration.
        return try PropertyListSerialization.data(fromPropertyList: ["version": 1, "entries": entries], format: .binary, options: 0)
    }
}
