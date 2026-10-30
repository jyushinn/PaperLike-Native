import Foundation
import PaperlikeCore

func lightingAutomationSettingsTests() -> [TestCase] {
    [
        TestCase("LightingAutomationSettingsTests.corruptDataIsPreserved") {
            let suite = "PaperlikeCorruptAutomation.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let raw = Data([0xFF, 0x00])
            defaults.set(raw, forKey: "PaperLikeNative.LightingAutomationSettings")
            let store = LightingAutomationSettingsStore(defaults: defaults)
            try expectEqual(store.load(), LightingAutomationSettings())
            try expect(store.recoveredCorruptData, "corrupt data must be reported")
            try expectEqual(defaults.data(forKey: LightingAutomationSettingsStore.corruptBackupKey), raw)
        },
        TestCase("LightingAutomationSettingsTests.defaultsAndRoundTrips") {
            let suite = "PaperlikeAutomationTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = LightingAutomationSettingsStore(defaults: defaults)

            try expectEqual(store.load(), LightingAutomationSettings())

            let rule = LightingScheduleRule(
                name: "工作日",
                weekdays: [
                    .monday,
                    .tuesday,
                    .wednesday,
                    .thursday,
                    .friday
                ],
                start: MinuteOfDay(hour: 9, minute: 0),
                end: MinuteOfDay(hour: 18, minute: 0),
                configuration: LightingConfiguration(
                    frontLightMode: 3,
                    brightness: 60,
                    temperature: 45
                )
            )
            let expected = LightingAutomationSettings(
                isEnabled: true,
                rules: [rule]
            )

            try store.save(expected)

            try expectEqual(store.load(), expected)
        },
        TestCase("LightingAutomationSettingsTests.clampsDeviceValues") {
            let value = LightingConfiguration(
                frontLightMode: 8,
                brightness: 120,
                temperature: -10
            )

            try expectEqual(value.frontLightMode, 3)
            try expectEqual(value.brightness, 100)
            try expectEqual(value.temperature, 0)
        },
        TestCase("LightingAutomationSettingsTests.clampsMinuteOfDay") {
            try expectEqual(MinuteOfDay(-1).value, 0)
            try expectEqual(MinuteOfDay(1_440).value, 1_439)
            try expectEqual(
                MinuteOfDay(hour: 9, minute: 30).value,
                570
            )
        }
    ]
}
