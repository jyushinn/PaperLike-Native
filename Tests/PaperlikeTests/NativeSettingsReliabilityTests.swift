import Foundation
import PaperlikeCore
import PaperlikeTouch
import ServiceManagement
@testable import PaperLikeNativeUI

func nativeSettingsReliabilityTests() -> [TestCase] {
    func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/PaperLikeNativeUI/\(name)"), encoding: .utf8)
    }
    return [
        TestCase("NativeSettings.legacyRuleRepairAndHotkeyRetryAreReachable") {
            let model = try source("AppModel.swift")
            try expect(model.contains("appRuleDraft"), "invalid legacy app rules need a draft that survives intermediate validation failures")
            try expect(model.contains("automationRuleDraft"), "invalid legacy automation rules need the same repair path")
            try expect(model.contains("retrySavedHotKeys"), "unchanged saved shortcuts need an explicit registration retry")
            try expect(try source("SettingsView.swift").contains("重试已保存快捷键"), "registration failure needs a visible recovery entry")
        },
        TestCase("NativeSettings.oversizedLegacyRulesCanBeRepairedAcrossEdits") {
            let original = (0..<202).map { AppAdaptationRule(bundleIdentifier: "legacy.\($0)", appName: "App", mode: .text) }
            var persisted = AppSettings(appRules: original)
            var sideEffects = 0
            var draft = RuleEditingDraft<AppAdaptationRule>()
            let validate: ([AppAdaptationRule]) throws -> Void = { try AppSettings(appRules: $0).validate() }
            let save: ([AppAdaptationRule]) throws -> Void = { persisted.rules = $0; sideEffects += 1 }
            draft.update(Array(original.dropLast()), validate: validate, save: save)
            try expectEqual(draft.rules?.count, 201)
            try expect(draft.message?.contains("还需删除 1 条") == true, "remaining error must guide the next repair")
            try expectEqual(persisted.rules.count, 202)
            try expectEqual(sideEffects, 0)
            draft.update(Array(draft.rules!.dropLast()), validate: validate, save: save)
            try expectEqual(persisted.rules.count, 200)
            try expect(draft.rules == nil && draft.message == nil, "successful final repair clears the draft")
            try expectEqual(sideEffects, 1)
        },
        TestCase("NativeSettings.multipleLegacyRuleErrorsRemainEditableAndDiscardable") {
            func rule(_ name: String) -> LightingScheduleRule {
                LightingScheduleRule(name: name, weekdays: [.monday], start: MinuteOfDay(60), end: MinuteOfDay(120), configuration: LightingConfiguration(frontLightMode: 1, brightness: 30, temperature: 30))
            }
            let original = [rule(""), rule(String(repeating: "x", count: 121))]
            var persisted = LightingAutomationSettings(rules: original)
            var sideEffects = 0
            var draft = RuleEditingDraft<LightingScheduleRule>()
            let validate: ([LightingScheduleRule]) throws -> Void = { try LightingAutomationSettings(rules: $0).validate() }
            let save: ([LightingScheduleRule]) throws -> Void = { persisted.rules = $0; sideEffects += 1 }
            var repaired = original
            repaired[0].name = "早晨"
            draft.update(repaired, validate: validate, save: save)
            try expectEqual(draft.rules?[0].name, "早晨")
            try expect(draft.message?.contains("还有 1 条") == true, "one remaining invalid rule must be visible")
            try expectEqual(persisted.rules, original)
            try expectEqual(sideEffects, 0)
            draft.discard()
            try expect(draft.rules == nil, "discard returns the editor to persisted rules")
            try expectEqual(persisted.rules, original)
            draft.update(repaired, validate: validate, save: save)
            repaired = draft.rules!
            repaired[1].name = "傍晚"
            draft.update(repaired, validate: validate, save: save)
            try expectEqual(persisted.rules, repaired)
            try expectEqual(sideEffects, 1)
        },
        TestCase("NativeSettings.ruleDraftSurvivesStorageFailureWithoutApplyingControls") {
            var draft = RuleEditingDraft<AppAdaptationRule>()
            let candidate = [AppAdaptationRule(bundleIdentifier: "example.app", appName: "App", mode: .text)]
            var applied = false
            draft.update(candidate, validate: SettingsValidation.validateAppRules, save: { _ in
                throw SettingsValidationError.invalid("模拟保存失败")
            })
            try expectEqual(draft.rules, candidate)
            try expectEqual(draft.message, "模拟保存失败")
            draft.update(draft.rules!, validate: SettingsValidation.validateAppRules, save: { _ in applied = true })
            try expect(applied && draft.rules == nil, "retry can save unchanged valid draft")
            let model = try source("AppModel.swift")
            try expect(model.contains("if self.saveSettings() { self.applyCalibration() }"), "calibration cannot apply before settings validation and save")
        },
        TestCase("NativeSettings.processTimeoutKillsChildAndReleasesQueue") {
            let runner = AppleScriptRunner(timeout: 0.08, executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; exec /bin/sleep 5"])
            let start = Date()
            var timedOut = false
            do { try await runner.run("") } catch let error as NSError { timedOut = error.code == -1001 }
            try expect(timedOut, "hung child reports timeout")
            try await AppleScriptRunner(timeout: 1, executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: []).run("")
            try expect(Date().timeIntervalSince(start) < 1.5, "terminated child must release the serial process queue")
        },
        TestCase("NativeSettings.inheritedStderrCannotBlockNextProcess") {
            let runner = AppleScriptRunner(timeout: 0.05, executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "(trap '' HUP TERM; /bin/sleep 2) & wait"])
            do { try await runner.run("") } catch { }
            try await AppleScriptRunner(timeout: 0.8, executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: []).run("")
        },
        TestCase("NativeSettings.processCancellationStopsRunningAndQueuedWork") {
            let runner = AppleScriptRunner(timeout: 3, executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
            let running = Task { try await runner.run("") }
            try await Task.sleep(for: .milliseconds(40))
            let queued = Task { try await runner.run("") }
            queued.cancel()
            running.cancel()
            for task in [running, queued] {
                var cancelled = false
                do { try await task.value } catch is CancellationError { cancelled = true }
                try expect(cancelled, "both launched and queued operations must throw CancellationError")
            }
            try await AppleScriptRunner(timeout: 1, executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: []).run("")
        },
        TestCase("NativeSettings.hotkeyRollbackReportsActualRegistrations") {
            try await MainActor.run {
                var failedCodes: Set<UInt32> = []
                let service = HotKeyService(registerKey: { _, definition in
                    if failedCodes.contains(definition.keyCode) { throw HotKeyServiceError.registrationFailed(-1) }
                    return OpaquePointer(bitPattern: Int(definition.keyCode) + 1)!
                }, unregisterKey: { _ in })
                let old: [HotKeyAction: HotKeyDefinition] = [.cycleMode: HotKeyDefinition(keyCode: 1, modifiers: 0x100), .refresh: HotKeyDefinition(keyCode: 2, modifiers: 0x100)]
                try service.apply(definitions: old, handlers: [:])
                failedCodes = [9]
                var rejected = false
                do { try service.apply(definitions: [.cycleMode: HotKeyDefinition(keyCode: 9, modifiers: 0x100)], handlers: [:]) }
                catch { rejected = true }
                try expect(rejected, "new registration failure must be reported")
                try expectEqual(service.registeredDefinitions, old)
                failedCodes = [2, 9]
                var failedRestore = false
                do { try service.apply(definitions: [.cycleMode: HotKeyDefinition(keyCode: 9, modifiers: 0x100)], handlers: [:]) }
                catch HotKeyServiceError.rollbackFailed { failedRestore = true }
                try expect(failedRestore, "rollback failure must remain observable")
                try expectEqual(service.registeredDefinitions, [.cycleMode: old[.cycleMode]!])
                try expectEqual(service.registrationIssues(comparedTo: old), [.refresh])
                failedCodes = []
                try service.apply(definitions: old, handlers: [:])
                try expectEqual(service.registeredDefinitions, old)
                try expect(service.registrationIssues(comparedTo: old).isEmpty, "retrying the same saved combinations must restore registration and clear status")
            }
        },
        TestCase("NativeSettings.loginStatusesAndImportImpactRemainDistinct") {
            try expect(LoginItemStatus(.requiresApproval).isRequested, "approval pending remains requested")
            try expect(!LoginItemStatus(.notFound).isRequested, "missing app must not appear enabled")
            try expectEqual(LoginItemStatus(.enabled), .enabled)
            let before = ConfigurationBackup(settings: AppSettings(), automation: LightingAutomationSettings(), touch: .default, presets: [])
            var settings = AppSettings(); settings.modeHotKey = HotKeyDefinition(keyCode: 1, modifiers: 0x100); settings.saturationValue = 0.2
            let after = ConfigurationBackup(settings: settings, automation: LightingAutomationSettings(), touch: .default, presets: [])
            let summary = after.impactSummary(comparedTo: before).joined(separator: "\n")
            try expect(summary.contains("快捷键将立即更换"), "immediate hotkey effect must be explicit")
            try expect(summary.contains("恢复自动控制时应用"), "deferred display effect must be explicit")
        },
        TestCase("NativeSettings.systemProcessHasCancellationBoundary") {
            let runner = try source("AppleScriptRunner.swift")
            try expect(runner.contains("withTaskCancellationHandler"), "system process must observe cancellation")
        },
        TestCase("NativeSettings.rejectsUnexportableDailyRules") {
            let suite = "PaperlikeTests.validation.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AppSettingsStore(defaults: defaults)
            for invalid in [
                AppSettings(appRules: (0...200).map { AppAdaptationRule(bundleIdentifier: "test.\($0)", appName: "App", mode: .text) }),
                AppSettings(appRules: [AppAdaptationRule(bundleIdentifier: "test.app", appName: String(repeating: "x", count: 121), mode: .text)])
            ] {
                var rejected = false
                do { try store.save(invalid) } catch { rejected = true }
                try expect(rejected, "daily settings must reject rules that backup cannot export")
                try expectEqual(store.load(), AppSettings())
            }
        },
        TestCase("NativeSettings.acceptedRuleLimitsRoundTripBackup") {
            let appRules = (0..<200).map { AppAdaptationRule(bundleIdentifier: String(repeating: "x", count: 250) + String(format: "%05d", $0), appName: String(repeating: "n", count: 120), mode: .text) }
            let automationRules = (0..<200).map { _ in LightingScheduleRule(name: String(repeating: "n", count: 120), weekdays: [.monday], start: MinuteOfDay(60), end: MinuteOfDay(120), configuration: LightingConfiguration(frontLightMode: 1, brightness: 30, temperature: 30)) }
            let settings = AppSettings(appRules: appRules)
            let automation = LightingAutomationSettings(rules: automationRules)
            try settings.validate(); try automation.validate()
            let backup = ConfigurationBackup(settings: settings, automation: automation, touch: .default, presets: [])
            try expectEqual(try ConfigurationBackup.decode(backup.encoded()), backup)
        },
        TestCase("NativeSettings.rejectsUnexportableAutomationRules") {
            let suite = "PaperlikeTests.automation-validation.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = LightingAutomationSettingsStore(defaults: defaults)
            let rule = LightingScheduleRule(name: String(repeating: "x", count: 121), weekdays: [.monday], start: MinuteOfDay(60), end: MinuteOfDay(120), configuration: LightingConfiguration(frontLightMode: 1, brightness: 30, temperature: 30))
            var rejected = false
            do { try store.save(LightingAutomationSettings(rules: [rule])) } catch { rejected = true }
            try expect(rejected, "daily automation save must share backup name limit")
        },
        TestCase("NativeSettings.editorOwnsDraftIdentity") {
            let editor = try source("ScheduleRuleEditorView.swift")
            try expect(editor.contains("@StateObject private var editor"), "editor-owned drafts must survive parent publication")
            let settings = try source("SettingsView.swift")
            try expect(settings.contains(".sheet(item: $model.editingAutomationRule)"), "the stable settings root must own rule presentation")
            try expect(settings.contains(".id(rule.id)"), "different rules must have separate editing identities")
            try expect(!(try source("AutomationSettingsView.swift")).contains(".sheet(item:"), "destination changes must not destroy the rule editor")
        },
        TestCase("NativeSettings.hotkeyRollbackIsNotSilenced") {
            try expect(!(try source("HotKeyService.swift")).contains("try? register(previousDefinitions)"), "restore failures must be reported")
            try expect(!(try source("AppModel.swift")).contains("try? configureHotKeys(using: savedSettings)"), "settings restore must not hide hotkey restore failures")
        },
        TestCase("NativeSettings.importAndRecoveryDescribeActualEffects") {
            let configuration = try source("ConfigurationSettingsView.swift")
            try expect(configuration.contains("恢复自动控制"), "resume label must describe automatic controls")
            try expect(configuration.contains("impactSummary"), "import confirmation must compare previous and incoming configuration")
            try expect(try source("QuickPanelView.swift").contains("Button(L(\"继续触控\")"), "paused touch should resume in place")
        },
        TestCase("NativeSettings.loginRegistrationRequiresUserChoice") {
            let model = try source("AppModel.swift")
            try expect(!model.contains("try loginItem.setEnabled(true)"), "initialization must not register login item automatically")
            try expect(try source("LoginItemService.swift").contains("requiresApproval"), "approval-pending must have a distinct status")
        }
    ]
}
