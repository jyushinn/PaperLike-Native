import Foundation
import PaperlikeCore
import PaperlikeTouch
@testable import PaperLikeNativeUI

func configurationBackupTests() -> [TestCase] {
    [
        TestCase("ConfigurationRecovery.wrongTypesAreReportedAndFirstBackupSurvives") {
            try await MainActor.run {
                let suite = "PaperlikeWrongType.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                for section in RawConfigurationArchive.keys {
                    let key = "PaperLikeNative." + section
                    let backup = key + ".CorruptBackup"
                    for raw in ["invalid type", "replacement invalid type"] {
                        defaults.set(raw, forKey: key)
                        var reported = false
                        switch section {
                        case "AppSettings":
                            let store = AppSettingsStore(defaults: defaults)
                            _ = store.load()
                            reported = store.recoveredCorruptData
                            try store.save(AppSettings())
                        case "LightingAutomationSettings":
                            let store = LightingAutomationSettingsStore(defaults: defaults)
                            _ = store.load()
                            reported = store.recoveredCorruptData
                            try store.save(LightingAutomationSettings())
                        case "TouchMappingSettings":
                            let store = TouchSettingsStore(defaults: defaults)
                            try expect(!store.load().isEnabled, "corrupt touch settings stay disabled")
                            reported = store.recoveredCorruptData
                        case "DisplayPresets":
                            _ = PresetStore.load(defaults: defaults) { reported = true }
                        default:
                            _ = FrontLightPresetStore.load(defaults: defaults) { reported = true }
                        }
                        try expect(reported, "wrong type must trigger recovery for \(section)")
                        try expectEqual(defaults.string(forKey: backup), "invalid type")
                    }
                }
            }
        },
        TestCase("RawConfigurationArchive.preservesBytesAndInvalidTypesWithoutUnrelatedDefaults") {
            let suite = "PaperlikeRawArchive.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let raw = Data([0xFF, 0, 0xFE])
            defaults.set(raw, forKey: "PaperLikeNative.AppSettings.CorruptBackup")
            defaults.set("invalid type", forKey: "PaperLikeNative.DisplayPresets")
            defaults.set("secret", forKey: "unrelated")
            let data = try RawConfigurationArchive.encoded(defaults: defaults)
            let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
            let entries = root["entries"] as! [String: Any]
            try expectEqual(entries["PaperLikeNative.AppSettings.CorruptBackup"] as? Data, raw)
            try expectEqual(entries["PaperLikeNative.DisplayPresets"] as? String, "invalid type")
            try expect(entries["unrelated"] == nil, "export only configuration keys")
            try expectEqual(defaults.string(forKey: "PaperLikeNative.DisplayPresets"), "invalid type")
        },
        TestCase("PresetStore.corruptDataIsPreservedWithoutOverwritingFirstBackup") {
            let suite = "PaperlikePresetRecovery.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let raw = Data([0xFF, 0x00])
            defaults.set(raw, forKey: "PaperLikeNative.DisplayPresets")
            defaults.set(raw, forKey: "PaperLikeNative.FrontLightPresets")
            var reports = 0
            _ = PresetStore.load(defaults: defaults, onCorruption: { reports += 1 })
            _ = FrontLightPresetStore.load(defaults: defaults, onCorruption: { reports += 1 })
            try expectEqual(reports, 2)
            for key in [PresetStore.corruptBackupKey, FrontLightPresetStore.corruptBackupKey] {
                try expectEqual(defaults.data(forKey: key), raw)
            }
            defaults.set(Data([0x01]), forKey: "PaperLikeNative.DisplayPresets")
            _ = PresetStore.load(defaults: defaults)
            try expectEqual(defaults.data(forKey: PresetStore.corruptBackupKey), raw)
            try expectEqual(defaults.data(forKey: "PaperLikeNative.FrontLightPresets"), raw)
            defaults.set(Data("[]".utf8), forKey: "PaperLikeNative.DisplayPresets")
            _ = PresetStore.load(defaults: defaults, onCorruption: { reports += 1 })
            try expectEqual(reports, 2)
        },
        TestCase("AppleScriptRunner.propagatesChildScriptErrors") {
            let runner = AppleScriptRunner()
            try await runner.run("return 42")
            do {
                try await runner.run("this is not valid AppleScript !!")
                throw TestFailure(description: "invalid script was accepted")
            } catch let error as NSError {
                try expectEqual(error.domain, "PaperLikeNative.AppleScript")
                try expect(!error.localizedDescription.isEmpty, "child error is preserved")
            }
        },
        TestCase("ConfigurationImport.restoresPauseAndConfigurationAfterFailure") {
            for initialPause in [false, true] {
                var paused = initialPause
                var value = "original"
                try expectThrows(ConfigurationBackupError.invalidValues) {
                    try ConfigurationImportTransaction.perform(wasPaused: initialPause,
                        setPaused: { paused = $0 }, replace: {
                            try expect(paused, "replacement runs with automatic controls suspended")
                            value = "partial"
                            throw ConfigurationBackupError.invalidValues
                        }, rollback: { value = "original" })
                }
                try expectEqual(paused, initialPause)
                try expectEqual(value, "original")
            }
        },
        TestCase("ConfigurationImport.rollbackFailureKeepsPartialConfigurationPaused") {
            for initialPause in [false, true] {
                var paused = initialPause
                var transitions: [Bool] = []
                var value = "original"
                var failureMessage: String?
                do {
                    try ConfigurationImportTransaction.perform(wasPaused: initialPause,
                        setPaused: { paused = $0; transitions.append($0) }, replace: {
                            try expect(paused, "replacement must start while paused")
                            value = "partially-replaced"
                            throw NSError(domain: "Test.replace", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "replacement failed"])
                        }, rollback: {
                            try expect(paused, "rollback must run while paused")
                            throw NSError(domain: "Test.rollback", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "rollback failed"])
                        })
                } catch { failureMessage = error.localizedDescription }
                try expect(paused, "failed rollback must never resume automatic controls on partially replaced settings")
                try expectEqual(transitions, [true])
                try expectEqual(value, "partially-replaced")
                try expect(failureMessage?.contains("replacement failed") == true,
                    "compound error must preserve the original failure")
                try expect(failureMessage?.contains("rollback failed") == true,
                    "compound error must preserve the rollback failure")
            }
        },
        TestCase("ConfigurationImport.successWaitsForExplicitResume") {
            var paused = false
            var value = "original"
            try ConfigurationImportTransaction.perform(wasPaused: false,
                setPaused: { paused = $0 }, replace: { value = "imported" },
                rollback: { value = "original" })
            try expect(paused, "successful import remains suspended for user review")
            try expectEqual(value, "imported")
        },
        TestCase("ConfigurationBackup.dailyUnicodeNamesMustFitBackupBudget") {
            let family = String(repeating: "👨‍👩‍👧‍👦", count: 120)
            try expectEqual(family.count, 120)
            try expectEqual(family.utf8.count, 3_000)
            let domain = "PaperlikeTests.unicode.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let apps = AppSettings(appRules: (0..<200).map {
                AppAdaptationRule(bundleIdentifier: "example.\($0)", appName: family, mode: .text)
            })
            let automation = LightingAutomationSettings(rules: (0..<200).map { _ in
                LightingScheduleRule(name: family, weekdays: [.monday], start: MinuteOfDay(60), end: MinuteOfDay(120), configuration: LightingConfiguration(frontLightMode: 1, brightness: 30, temperature: 30))
            })
            var rejected = 0
            do { try AppSettingsStore(defaults: defaults).save(apps) } catch { rejected += 1 }
            do { try LightingAutomationSettingsStore(defaults: defaults).save(automation) } catch { rejected += 1 }
            try expectEqual(rejected, 2)
            try expect(!DisplayPreset(name: family, mode: .text, threshold: 5).isValid, "display preset names must share the UTF-8 boundary")
            try expect(!FrontLightPreset(name: family, configuration: LightingConfiguration(frontLightMode: 1, brightness: 30, temperature: 30)).isValid, "front-light names must share the UTF-8 boundary")
        },
        TestCase("ConfigurationBackup.allFiveAcceptedSectionsFitTogether") {
            try expectEqual(SettingsValidation.maximumSectionBytes, TouchMappingSettings.maximumSectionBytes)
            let name = String(repeating: "😀", count: 120)
            let settings = AppSettings(appRules: (0..<200).map {
                AppAdaptationRule(bundleIdentifier: "example.\($0)", appName: name, mode: .text)
            })
            let lighting = LightingConfiguration(frontLightMode: 1, brightness: 30, temperature: 30)
            let automation = LightingAutomationSettings(rules: (0..<200).map { _ in
                LightingScheduleRule(name: name, weekdays: [.monday], start: MinuteOfDay(60), end: MinuteOfDay(120), configuration: lighting)
            })
            let touch = TouchMappingSettings(displaySelection: .stable(String(repeating: "x", count: 190_000)))
            let backup = ConfigurationBackup(settings: settings, automation: automation, touch: touch,
                presets: (0..<200).map { _ in DisplayPreset(name: name, mode: .text, threshold: 5) },
                frontLightPresets: (0..<200).map { _ in FrontLightPreset(name: name, configuration: lighting) })
            let data = try backup.encoded()
            try expect(data.count <= 1_048_576, "all five accepted sections must fit the import limit")
            try expectEqual(try ConfigurationBackup.decode(data), backup)
            let domain = "PaperlikeTests.budget.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let store = AppSettingsStore(defaults: defaults)
            try store.save(settings)
            let escaped = AppSettings(appRules: (0..<200).map {
                AppAdaptationRule(bundleIdentifier: String(repeating: "\u{1}", count: 250) + String($0),
                    appName: String(repeating: "\u{1}", count: 120), mode: .text)
            })
            try escaped.validate()
            var rejected = false
            do { try store.save(escaped) } catch { rejected = true }
            try expect(rejected, "JSON escaping must count toward the same saved section budget")
            try expectEqual(store.load(), settings)
            var exportRejected = false
            do {
                _ = try ConfigurationBackup(settings: escaped, automation: automation, touch: .default, presets: []).encoded()
            } catch { exportRejected = true }
            try expect(exportRejected, "save and backup must reject the same oversized section")
        },
        TestCase("ConfigurationBackup.roundTripsWithoutPermissions") {
            let backup = ConfigurationBackup(settings: AppSettings(), automation: LightingAutomationSettings(),
                touch: TouchMappingSettings(isEnabled: false), presets: DisplayPreset.builtIns)
            let data = try backup.encoded()
            try expectEqual(try ConfigurationBackup.decode(data), backup)
            try expect(!String(decoding: data, as: UTF8.self).contains("isAccessibilityTrusted"), "permissions not backed up")
        },
        TestCase("ConfigurationBackup.rejectsInvalidVersionAndRanges") {
            let backup = ConfigurationBackup(settings: AppSettings(), automation: LightingAutomationSettings(),
                touch: .default, presets: DisplayPreset.builtIns)
            var raw = try JSONSerialization.jsonObject(with: backup.encoded()) as! [String: Any]
            raw["version"] = 99
            try expectThrows(ConfigurationBackupError.unsupportedVersion) {
                _ = try ConfigurationBackup.decode(JSONSerialization.data(withJSONObject: raw))
            }
            raw["version"] = 1
            var settings = raw["settings"] as! [String: Any]
            settings["autoRefreshIntervalSeconds"] = 0
            raw["settings"] = settings
            try expectThrows(ConfigurationBackupError.invalidValues) {
                _ = try ConfigurationBackup.decode(JSONSerialization.data(withJSONObject: raw))
            }
        },
        TestCase("ConfigurationBackup.rejectsOversizedInputAndDuplicatePresets") {
            try expectThrows(ConfigurationBackupError.tooLarge) {
                _ = try ConfigurationBackup.decode(Data(repeating: 0, count: 1_048_577))
            }
            let preset = DisplayPreset.builtIns[0]
            let backup = ConfigurationBackup(settings: AppSettings(), automation: LightingAutomationSettings(),
                touch: .default, presets: [preset, preset])
            try expectThrows(ConfigurationBackupError.invalidValues) { _ = try backup.encoded() }
            let tooManyLights = (0..<201).map { _ in
                FrontLightPreset(name: "test", configuration: LightingConfiguration(frontLightMode: 1, brightness: 30, temperature: 30))
            }
            let oversized = ConfigurationBackup(settings: AppSettings(), automation: LightingAutomationSettings(),
                touch: .default, presets: [], frontLightPresets: tooManyLights)
            try expectThrows(ConfigurationBackupError.invalidValues) { _ = try oversized.encoded() }
            try expectThrows(ConfigurationBackupError.invalidValues) { try FrontLightPresetStore.save(tooManyLights) }
        },
        TestCase("PresetStore.savingMySceneReplacesFirstAndKeepsLegacyEntries") {
            let first = DisplayPreset(name: "旧场景", mode: .web, threshold: 4)
            let legacy = DisplayPreset(name: "保留场景", mode: .active, threshold: 7)
            let edited = DisplayPreset(name: "我的场景", mode: .text, threshold: 5)

            let updated = DisplayPreset.updatingMyScene(existing: [first, legacy], with: edited)

            try expectEqual(updated.count, 2)
            try expectEqual(updated[0].id, first.id)
            try expectEqual(updated[0].name, "我的场景")
            try expectEqual(updated[0].mode, edited.mode)
            try expectEqual(updated[1], legacy)
        }
    ]
}
