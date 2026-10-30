import Foundation

public struct AppAdaptationRule: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var bundleIdentifier: String
    public var appName: String
    public var mode: DisplayMode
    public var threshold: Int
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        appName: String,
        mode: DisplayMode,
        threshold: Int = 5,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.mode = mode
        self.threshold = threshold
        self.isEnabled = isEnabled
    }
}
