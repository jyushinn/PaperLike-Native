import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static let preferenceKey = "PaperLikeNative.Language"

    public static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system
    }

    public var title: String {
        switch self {
        case .system: L("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    public func resolvedIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .simplifiedChinese: return "zh-Hans"
        case .english: return "en"
        case .system:
            for language in preferredLanguages {
                let code = language.lowercased().replacingOccurrences(of: "_", with: "-")
                if code == "zh" || code.hasPrefix("zh-") { return "zh-Hans" }
                if code == "en" || code.hasPrefix("en-") { return "en" }
            }
            return "en"
        }
    }

    public var locale: Locale { Locale(identifier: resolvedIdentifier()) }
}

public struct LocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]

    public init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append(String(describing: value))
        }
    }
}

private enum LocalizationResources {
    static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: ["en", "zh-Hans"].map { identifier in
        let resourceLanguage = Bundle.module.localizations.first {
            $0.caseInsensitiveCompare(identifier) == .orderedSame
        } ?? identifier
        let bundle = Bundle.module.path(forResource: resourceLanguage, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? Bundle.module
        return (identifier, bundle)
    })
}

public func L(_ text: LocalizedText) -> String {
    let identifier = AppLanguage.current.resolvedIdentifier()
    let bundle = LocalizationResources.bundles[identifier] ?? Bundle.module
    let translated = bundle.localizedString(forKey: text.key, value: text.key, table: nil)
    guard !text.arguments.isEmpty else { return translated }
    return String(format: translated, locale: Locale(identifier: identifier), arguments: text.arguments)
}
