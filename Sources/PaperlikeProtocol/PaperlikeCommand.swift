public enum PaperlikeCommand: UInt8, Sendable {
    case threshold = 0x01
    case mode = 0x02
    case refresh = 0x03
    case speed = 0x04
    case realTimeClock = 0x05
    case frontLightMode = 0x07
    case frontLightTemperature = 0x08
    case frontLightBrightness = 0x09
    case query = 0x0A
    case keepAlive = 0x20
    case identify = 0xF0
}
