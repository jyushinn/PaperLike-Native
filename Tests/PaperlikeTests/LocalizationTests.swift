import Foundation
@testable import PaperLikeNativeUI
import PaperlikeLocalization
import PaperlikeCore

func localizationTests() -> [TestCase] {
    [TestCase("Manual English preference changes settings titles") {
        let key = "PaperLikeNative.Language"
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        UserDefaults.standard.setVolatileDomain([key: "en"], forName: UserDefaults.argumentDomain)
        try expectEqual(SettingsDestination.general.title, "General")
        try expectEqual(L("删除 \("我的预设 50%")"), "Delete 我的预设 50%")
        try expectEqual(L("版本 \("1.0") (Build \(17))"), "Version 1.0 (Build 17)")
        try expectEqual(ConnectionPresentation(state: .disconnected).title, "Disconnected")
        UserDefaults.standard.setVolatileDomain([key: "zh-Hans"], forName: UserDefaults.argumentDomain)
        try expectEqual(SettingsDestination.general.title, "通用")
    }, TestCase("System language follows ordered preferences with English fallback") {
        try expectEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["fr-FR", "zh-Hans-CN", "en-US"]), "zh-Hans")
        try expectEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["en-GB", "zh-CN"]), "en")
        try expectEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["zh-Hant-TW"]), "zh-Hans")
        try expectEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["de-DE"]), "en")
        try expectEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: []), "en")
        try expectEqual(AppLanguage.english.resolvedIdentifier(preferredLanguages: ["zh-Hans"]), "en")
        try expectEqual(AppLanguage.simplifiedChinese.resolvedIdentifier(preferredLanguages: ["en"]), "zh-Hans")
    }, TestCase("Language preference survives model recreation without changing device settings") {
        try await MainActor.run {
            let defaults = UserDefaults.standard
            let key = AppLanguage.preferenceKey
            let previousDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            let previousValue = defaults.object(forKey: key)
            let previousEnvironment = ProcessInfo.processInfo.environment["PAPERLIKE_UI_PREVIEW"]
            defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
            setenv("PAPERLIKE_UI_PREVIEW", "1", 1)
            defer {
                if let previousValue { defaults.set(previousValue, forKey: key) }
                else { defaults.removeObject(forKey: key) }
                defaults.setVolatileDomain(previousDomain, forName: UserDefaults.argumentDomain)
                if let previousEnvironment { setenv("PAPERLIKE_UI_PREVIEW", previousEnvironment, 1) }
                else { unsetenv("PAPERLIKE_UI_PREVIEW") }
            }
            let model = AppModel()
            let settings = model.settings
            let automation = model.automationSettings
            model.language = .english
            try expectEqual(AppLanguage.current, .english)
            try expectEqual(AppModel().language, .english)
            try expectEqual(SettingsDestination.general.title, "General")
            model.language = .simplifiedChinese
            try expectEqual(SettingsDestination.general.title, "通用")
            try expectEqual(model.settings, settings)
            try expectEqual(model.automationSettings, automation)
            model.language = .system
            try expectEqual(AppModel().language, .system)
        }
    }]
}
