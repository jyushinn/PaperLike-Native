public struct ResponseStreamDecoder: Sendable {
    private static let header = Array("5FF5".utf8)
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(
        _ bytes: [UInt8]
    ) throws -> [PaperlikeResponse] {
        buffer.append(contentsOf: bytes)
        var responses: [PaperlikeResponse] = []

        while true {
            guard let headerIndex = buffer.firstRange(
                of: Self.header
            )?.lowerBound else {
                retainPossibleHeaderPrefix()
                break
            }

            if headerIndex > buffer.startIndex {
                buffer.removeFirst(headerIndex)
            }
            guard buffer.count >= 24 else {
                break
            }

            let frame = Array(buffer.prefix(24))
            do {
                responses.append(try PaperlikeResponse.decode(frame))
                buffer.removeFirst(24)
            } catch {
                buffer.removeFirst()
            }
        }

        return responses
    }

    private mutating func retainPossibleHeaderPrefix() {
        let maximumLength = min(buffer.count, Self.header.count - 1)
        for length in stride(from: maximumLength, through: 1, by: -1) {
            if buffer.suffix(length).elementsEqual(Self.header.prefix(length)) {
                buffer = Array(buffer.suffix(length))
                return
            }
        }
        buffer.removeAll(keepingCapacity: true)
    }
}
