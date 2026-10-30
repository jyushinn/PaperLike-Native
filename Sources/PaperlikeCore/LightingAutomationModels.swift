import Foundation

public enum Weekday: Int, CaseIterable, Codable, Hashable, Sendable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
}

public struct MinuteOfDay:
    Codable,
    Comparable,
    Equatable,
    Hashable,
    Sendable
{
    public let value: Int

    public init(_ value: Int) {
        self.value = min(1_439, max(0, value))
    }

    public init(hour: Int, minute: Int) {
        self.init(hour * 60 + minute)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(Int.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct LightingConfiguration:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let frontLightMode: Int
    public let brightness: Int
    public let temperature: Int

    public init(
        frontLightMode: Int,
        brightness: Int,
        temperature: Int
    ) {
        self.frontLightMode = min(3, max(0, frontLightMode))
        self.brightness = min(100, max(0, brightness))
        self.temperature = min(100, max(0, temperature))
    }

    private enum CodingKeys: String, CodingKey {
        case frontLightMode
        case brightness
        case temperature
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            frontLightMode: try container.decode(
                Int.self,
                forKey: .frontLightMode
            ),
            brightness: try container.decode(Int.self, forKey: .brightness),
            temperature: try container.decode(Int.self, forKey: .temperature)
        )
    }
}

public struct LightingScheduleRule:
    Identifiable,
    Codable,
    Equatable,
    Sendable
{
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var weekdays: Set<Weekday>
    public var start: MinuteOfDay
    public var end: MinuteOfDay
    public var configuration: LightingConfiguration

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        weekdays: Set<Weekday>,
        start: MinuteOfDay,
        end: MinuteOfDay,
        configuration: LightingConfiguration
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.weekdays = weekdays
        self.start = start
        self.end = end
        self.configuration = configuration
    }
}

public struct LightingAutomationSettings:
    Codable,
    Equatable,
    Sendable
{
    public var isEnabled: Bool
    public var rules: [LightingScheduleRule]

    public init(
        isEnabled: Bool = false,
        rules: [LightingScheduleRule] = []
    ) {
        self.isEnabled = isEnabled
        self.rules = rules
    }
}
