import Foundation
import PaperlikeCore

func appSettingsTests() -> [TestCase] {
    [
        TestCase("AppSettingsTests.corruptDataIsPreserved") {
            let suite = "PaperlikeCorruptSettings.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let raw = Data([0xFF, 0x00])
            defaults.set(raw, forKey: "PaperLikeNative.AppSettings")
            let store = AppSettingsStore(defaults: defaults)
            try expectEqual(store.load(), AppSettings())
            try expect(store.recoveredCorruptData, "corrupt data must be reported")
            try expectEqual(defaults.data(forKey: AppSettingsStore.corruptBackupKey), raw)
        },
        TestCase("AppSettingsTests.defaultsAndRoundTrips") {
            let suite = "PaperlikeTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AppSettingsStore(defaults: defaults)

            try expectEqual(store.load(), AppSettings())

            let expected = AppSettings(
                autoRefreshEnabled: true,
                autoRefreshIntervalSeconds: 75,
                modeHotKey: HotKeyDefinition(keyCode: 1, modifiers: 0x100),
                refreshHotKey: HotKeyDefinition(keyCode: 3, modifiers: 0x200),
                thresholdUpHotKey: nil,
                thresholdDownHotKey: HotKeyDefinition(
                    keyCode: 5,
                    modifiers: 0x800
                )
            )
            try store.save(expected)

            try expectEqual(store.load(), expected)
        },
        TestCase("AppSettingsTests.legacyCompatibility") {
            let suite = "PaperlikeTests.legacy.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            // Save standard legacy JSON to defaults
            let legacyJSON = """
            {
                "autoRefreshEnabled": true,
                "autoRefreshIntervalSeconds": 45
            }
            """.data(using: .utf8)!
            defaults.set(legacyJSON, forKey: "PaperLikeNative.AppSettings")

            let store = AppSettingsStore(defaults: defaults)
            let loaded = store.load()

            try expect(loaded.autoRefreshEnabled, "autoRefreshEnabled should be true")
            try expectEqual(loaded.autoRefreshIntervalSeconds, 45)
            try expect(!loaded.isAppAdaptationEnabled, "isAppAdaptationEnabled should default to false")
            try expect(loaded.rules.isEmpty, "rules should default to empty")
        },
        TestCase("AppSettingsTests.appAdaptationRoundTrips") {
            let suite = "PaperlikeTests.adaptation.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AppSettingsStore(defaults: defaults)

            let rule = AppAdaptationRule(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", mode: .text, threshold: 7, isEnabled: true)
            let settings = AppSettings(
                appAdaptationEnabled: true,
                appRules: [rule]
            )
            try store.save(settings)

            let loaded = store.load()
            try expect(loaded.isAppAdaptationEnabled, "isAppAdaptationEnabled should be true")
            try expectEqual(loaded.rules.count, 1)
            try expectEqual(loaded.rules.first?.bundleIdentifier, "com.apple.Terminal")
            try expectEqual(loaded.rules.first?.mode, .text)
            try expectEqual(loaded.rules.first?.threshold, 7)
            try expect(loaded.rules.first?.isEnabled ?? false, "rule should be enabled")
        }
    ]
}
