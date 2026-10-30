import Foundation

public enum PaperlikeProtocolError: Error, Equatable, Sendable {
    case parameterOutOfRange(Int)
    case invalidFrameLength(Int)
    case invalidHex
    case invalidHeader
    case invalidTrailer
}

public struct PaperlikeRequest: Equatable, Sendable {
    public let command: PaperlikeCommand
    public let parameter: Int

    public init(command: PaperlikeCommand, parameter: Int) {
        self.command = command
        self.parameter = parameter
    }

    public func encoded() throws -> [UInt8] {
        guard (0...255).contains(parameter) else {
            throw PaperlikeProtocolError.parameterOutOfRange(parameter)
        }

        return Array(
            String(
                format: "5FF5%02X%02X000000000000A0FA",
                command.rawValue,
                parameter
            ).utf8
        )
    }
}

public struct PaperlikeResponse: Equatable, Sendable {
    public let command: UInt8
    public let field1: UInt8
    public let field2: UInt8
    public let field3: UInt8

    public init(
        command: UInt8,
        field1: UInt8,
        field2: UInt8,
        field3: UInt8
    ) {
        self.command = command
        self.field1 = field1
        self.field2 = field2
        self.field3 = field3
    }

    public static func decode(_ bytes: [UInt8]) throws -> Self {
        guard bytes.count == 24 else {
            throw PaperlikeProtocolError.invalidFrameLength(bytes.count)
        }
        guard bytes.starts(with: Array("5FF5".utf8)) else {
            throw PaperlikeProtocolError.invalidHeader
        }
        guard bytes.suffix(4).elementsEqual(Array("A0FA".utf8)) else {
            throw PaperlikeProtocolError.invalidTrailer
        }

        return try Self(
            command: parseHexByte(bytes[4..<6]),
            field1: parseHexByte(bytes[6..<8]),
            field2: parseHexByte(bytes[8..<10]),
            field3: parseHexByte(bytes[10..<12])
        )
    }
}

private func parseHexByte(_ bytes: ArraySlice<UInt8>) throws -> UInt8 {
    guard
        bytes.count == 2,
        let text = String(bytes: bytes, encoding: .ascii),
        let value = UInt8(text, radix: 16)
    else {
        throw PaperlikeProtocolError.invalidHex
    }
    return value
}
