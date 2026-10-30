public enum DisplayMode: Int, CaseIterable, Codable, Sendable {
    case web = 6
    case text = 2
    case image = 3
    case active = 7

    /// Web writes use 6; the color firmware reports 1 in query register 0x02.
    public init?(queryValue: Int) {
        if queryValue == 1 { self = .web }
        else { self.init(rawValue: queryValue) }
    }
}

public struct DeviceState: Equatable, Sendable {
    public let profile: PaperlikeDeviceProfile
    public var mode: DisplayMode
    public var threshold: Int
    public var speed: Int?
    public var frontLightMode: Int
    public var brightness: Int
    public var temperature: Int

    public var frontLightAvailable: Bool {
        profile.hasFrontLight
    }

    public var speedDisplayText: String {
        switch speed {
        case 1:
            "快速"
        case 2:
            "快速+"
        case 3:
            "快速++"
        case 4:
            "快速+++"
        case 5:
            "快速++++"
        case let x? where x > 5:
            "未支持的速度值 (\(x))"
        default:
            "需手动选择"
        }
    }

    public init(
        profile: PaperlikeDeviceProfile,
        mode: DisplayMode,
        threshold: Int,
        speed: Int?,
        frontLightMode: Int,
        brightness: Int,
        temperature: Int
    ) {
        self.profile = profile
        self.mode = mode
        self.threshold = threshold
        self.speed = speed
        self.frontLightMode = frontLightMode
        self.brightness = brightness
        self.temperature = temperature
    }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting(path: String)
    case connected(name: String, state: DeviceState)
    case unsupported(identifier: String)
    case failed(message: String)
}

public enum DisplaySliderCommand: Equatable, Sendable {
    case threshold(Int), speed(Int)
}

/// At most one final target per slider; commands are discarded on disconnect.
public struct DisplaySliderQueue: Sendable {
    private var threshold: Int?
    private var speed: Int?
    public init() {}

    public mutating func submit(_ command: DisplaySliderCommand) {
        switch command {
        case let .threshold(value): threshold = value
        case let .speed(value): speed = value
        }
    }

    public mutating func next() -> DisplaySliderCommand? {
        if let value = threshold { threshold = nil; return .threshold(value) }
        if let value = speed { speed = nil; return .speed(value) }
        return nil
    }

    public mutating func removeAll() { threshold = nil; speed = nil }
}
