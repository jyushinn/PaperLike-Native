struct TestCase {
    let name: String
    let body: () async throws -> Void

    init(_ name: String, body: @escaping () async throws -> Void) {
        self.name = name
        self.body = body
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(
    _ condition: @autoclosure () throws -> Bool,
    _ message: String
) throws {
    guard try condition() else {
        throw TestFailure(description: message)
    }
}

func expectEqual<Value: Equatable>(
    _ actual: Value,
    _ expected: Value
) throws {
    guard actual == expected else {
        throw TestFailure(
            description: "expected \(expected), got \(actual)"
        )
    }
}

func expectThrows<Failure>(
    _ expected: Failure,
    _ body: () throws -> Void
) throws where Failure: Error & Equatable {
    do {
        try body()
        throw TestFailure(description: "expected \(expected), no error thrown")
    } catch let actual as Failure {
        try expectEqual(actual, expected)
    }
}
