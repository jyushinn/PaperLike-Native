import Foundation
import PaperlikeTouch

func touchSettingsStoreTests() -> [TestCase] {
    [
        TestCase("TouchSettingsStore.oversizedSavePreservesPreviousBlob") {
            try await MainActor.run {
                let harness = makeSettingsHarness()
                harness.store.save(.default)
                let before = harness.defaults.data(forKey: TouchSettingsStore.storageKey)
                let oversized = TouchMappingSettings(displaySelection: .stable(String(repeating: "x", count: 200_000)))
                harness.store.save(oversized)
                try expectEqual(harness.defaults.data(forKey: TouchSettingsStore.storageKey), before)
            }
        },
        TestCase("TouchSettingsStore.defaultsAreEnabledAutomaticAndDefaultCalibration") {
            try await MainActor.run {
                let harness = makeSettingsHarness()
                let settings = harness.store.load()

                try expectEqual(settings, .default)
                try expectEqual(settings.isEnabled, true)
                try expectEqual(settings.displaySelection, .automatic)
                try expectEqual(settings.calibration, .default)
            }
        },
        TestCase("TouchSettingsStore.roundTripsOneCodableBlob") {
            try await MainActor.run {
                let harness = makeSettingsHarness()
                let calibration = TouchCalibration(
                    minX: 100,
                    maxX: 4_000,
                    minY: 200,
                    maxY: 3_900,
                    swapAxes: true,
                    flipX: true
                )!
                let settings = TouchMappingSettings(
                    isEnabled: true,
                    displaySelection: .display(42),
                    calibration: calibration
                )

                harness.store.save(settings)

                try expectEqual(harness.store.load(), settings)
                try expect(harness.defaults.object(forKey: TouchSettingsStore.storageKey) is Data, "settings use one Data blob")
            }
        },
        TestCase("TouchSettingsStore.malformedBlobReturnsDefaultsWithoutDeletingUnrelatedPreferences") {
            try await MainActor.run {
                let harness = makeSettingsHarness()
                harness.defaults.set(Data([0xFF, 0x00]), forKey: TouchSettingsStore.storageKey)
                harness.defaults.set("keep", forKey: "UnrelatedPreference")

                try expectEqual(harness.store.load(), TouchMappingSettings(isEnabled: false))
                try expect(harness.store.recoveredCorruptData, "touch configuration damage must be reported")
                try expectEqual(harness.defaults.data(forKey: TouchSettingsStore.corruptBackupKey), Data([0xFF, 0x00]))
                try expectEqual(harness.defaults.string(forKey: "UnrelatedPreference"), "keep")
            }
        },
        TestCase("TouchSettingsStore.preservesExplicitOptOut") {
            try await MainActor.run {
                let harness = makeSettingsHarness()
                harness.store.save(TouchMappingSettings(isEnabled: false))
                try expectEqual(harness.store.load().isEnabled, false)
            }
        },
        TestCase("TouchSettingsStore.roundTripsStableSelectionAndPerDisplayCalibration") {
            try await MainActor.run {
                let harness = makeSettingsHarness()
                let calibration = TouchCalibration(minX: 200, maxX: 3_900, minY: 100, maxY: 3_800)!
                let settings = TouchMappingSettings(
                    isEnabled: false,
                    displaySelection: .stable("monitor-A"),
                    calibrationByDisplay: ["monitor-A": calibration]
                )
                harness.store.save(settings)

                try expectEqual(harness.store.load(), settings)
                try expectEqual(harness.store.load().isEnabled, false)
            }
        },
        TestCase("TouchSettingsStore.oldDisplayIDSelectionStillDecodes") {
            let oldJSON = """
            {"isEnabled":true,"displaySelection":{"mode":"display","displayID":42},"minX":100,"maxX":4000,"minY":200,"maxY":3900,"swapAxes":false,"flipX":false,"flipY":false}
            """.data(using: .utf8)!
            let settings = try JSONDecoder().decode(TouchMappingSettings.self, from: oldJSON)

            try expectEqual(settings.displaySelection, .display(42))
            try expectEqual(settings.calibration.minX, 100)
        },
        TestCase("TouchSettingsStore.restoreDefaultsReplacesOnlyTouchSettings") {
            try await MainActor.run {
                let harness = makeSettingsHarness()
                harness.store.save(TouchMappingSettings(isEnabled: true, displaySelection: .display(9)))
                harness.defaults.set(7, forKey: "UnrelatedPreference")

                try expectEqual(harness.store.restoreDefaults(), .default)
                try expectEqual(harness.store.load(), .default)
                try expectEqual(harness.defaults.integer(forKey: "UnrelatedPreference"), 7)
            }
        }
    ]
}

@MainActor
private final class SettingsHarness {
    let store: TouchSettingsStore
    let defaults: UserDefaults
    private let suiteName: String

    init() {
        suiteName = "PaperlikeTests.TouchSettings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = TouchSettingsStore(defaults: defaults)
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private func makeSettingsHarness() -> SettingsHarness {
    SettingsHarness()
}
