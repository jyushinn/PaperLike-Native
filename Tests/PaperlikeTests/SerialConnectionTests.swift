import Darwin
import Foundation
import SerialTransport

private struct PseudoTerminal {
    let master: Int32
    let slave: Int32
    let path: String

    init() throws {
        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        var name = [CChar](repeating: 0, count: 1024)
        guard openpty(
            &masterDescriptor,
            &slaveDescriptor,
            &name,
            nil,
            nil
        ) == 0 else {
            throw TestFailure(description: "openpty failed: \(errno)")
        }
        master = masterDescriptor
        slave = slaveDescriptor
        let end = name.firstIndex(of: 0) ?? name.endIndex
        path = String(decoding: name[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    func closeBoth() {
        Darwin.close(master)
        Darwin.close(slave)
    }
}

func serialConnectionTests() -> [TestCase] {
    [
        TestCase("SerialConnection.closeRejectsActiveAndQueuedFrames") {
            let terminal = try PseudoTerminal()
            defer { terminal.closeBoth() }
            let fixture = PartialWriteFixture()
            let connection = POSIXSerialConnection(path: terminal.path, writeBytes: { fixture.write($0, $1, $2) })
            try await connection.open()
            let first = Task { try await connection.write(Array("AAAAAA".utf8)) }
            try await fixture.waitForPartialWrite()
            let second = Task { try await connection.write(Array("BBBBBB".utf8)) }
            try await Task.sleep(for: .milliseconds(20))
            await connection.close()
            for writer in [first, second] {
                do { try await writer.value; throw TestFailure(description: "closed connection accepted a frame") }
                catch SerialTransportError.notOpen { }
            }
            try expectEqual(String(decoding: fixture.bytes, as: UTF8.self), "AA")
        },
        TestCase("SerialConnection.concurrentFramesStayContiguousUnderPartialWrite") {
            let terminal = try PseudoTerminal()
            defer { terminal.closeBoth() }
            let fixture = PartialWriteFixture()
            let connection = POSIXSerialConnection(path: terminal.path, writeBytes: { fixture.write($0, $1, $2) })
            try await connection.open()
            let first = Task { try await connection.write(Array("AAAAAA".utf8)) }
            try await fixture.waitForPartialWrite()
            let second = Task { try await connection.write(Array("BBBBBB".utf8)) }
            try await Task.sleep(for: .milliseconds(20))
            fixture.release()
            try await first.value
            try await second.value
            await connection.close()
            try expectEqual(String(decoding: fixture.bytes, as: UTF8.self), "AAAAAABBBBBB")
        },
        TestCase("SerialConnection.cancelledQueuedFrameNeverWrites") {
            let terminal = try PseudoTerminal()
            defer { terminal.closeBoth() }
            let fixture = PartialWriteFixture()
            let connection = POSIXSerialConnection(path: terminal.path, writeBytes: { fixture.write($0, $1, $2) })
            try await connection.open()
            let first = Task { try await connection.write(Array("AAAAAA".utf8)) }
            try await fixture.waitForPartialWrite()
            let second = Task { try await connection.write(Array("BBBBBB".utf8)) }
            try await Task.sleep(for: .milliseconds(20))
            second.cancel()
            fixture.release()
            try await first.value
            await connection.close()
            do { try await second.value; throw TestFailure(description: "queued cancelled write succeeded") }
            catch is CancellationError { }
            try expectEqual(String(decoding: fixture.bytes, as: UTF8.self), "AAAAAA")
        },
        TestCase("SerialConnectionTests.cancelsBackpressuredWrite") {
            let terminal = try PseudoTerminal()
            defer { terminal.closeBoth() }
            let connection = POSIXSerialConnection(path: terminal.path)
            try await connection.open()
            let writer = Task {
                do {
                    try await connection.write([UInt8](repeating: 65, count: 1_048_576))
                    return false
                } catch is CancellationError { return true }
                catch { return false }
            }
            try await Task.sleep(for: .milliseconds(50))
            writer.cancel()
            try await Task.sleep(for: .milliseconds(20))
            await connection.close()
            let cancelled = await writer.value
            try expect(cancelled, "backpressured writes must respond to cancellation")
        },
        TestCase("SerialConnectionTests.writesAllBytes") {
            let terminal = try PseudoTerminal()
            defer { terminal.closeBoth() }
            let connection = POSIXSerialConnection(path: terminal.path)
            try await connection.open()
            defer { Task { await connection.close() } }
            let expected = Array("5FF50203000000000000A0FA".utf8)

            try await connection.write(expected)
            var actual = [UInt8](repeating: 0, count: expected.count)
            let count = actual.withUnsafeMutableBytes {
                Darwin.read(terminal.master, $0.baseAddress, $0.count)
            }

            try expectEqual(count, expected.count)
            try expectEqual(actual, expected)
        },
        TestCase("SerialConnectionTests.readsIncomingBytes") {
            let terminal = try PseudoTerminal()
            defer { terminal.closeBoth() }
            let connection = POSIXSerialConnection(path: terminal.path)
            try await connection.open()
            defer { Task { await connection.close() } }
            let expected = Array("5FF50A010203".utf8)
            var iterator = connection.incomingBytes.makeAsyncIterator()

            _ = expected.withUnsafeBytes {
                Darwin.write(terminal.master, $0.baseAddress, expected.count)
            }
            let received = try await iterator.next()

            try expectEqual(received, expected)
        },
        TestCase("SerialConnectionTests.rejectsMissingPath") {
            let connection = POSIXSerialConnection(
                path: "/dev/cu.paperlike-does-not-exist"
            )

            do {
                try await connection.open()
                throw TestFailure(description: "missing path unexpectedly opened")
            } catch let error as SerialTransportError {
                try expectEqual(
                    error,
                    .openFailed(
                        path: "/dev/cu.paperlike-does-not-exist",
                        code: ENOENT
                    )
                )
            }
        },
        TestCase("SerialConnectionTests.exclusivelyLocksDevice") {
            let terminal = try PseudoTerminal()
            defer { terminal.closeBoth() }
            let connection = POSIXSerialConnection(
                path: terminal.path,
                makeExclusive: { _ in
                    errno = EBUSY
                    return -1
                }
            )

            do {
                try await connection.open()
                throw TestFailure(description: "exclusive lock unexpectedly succeeded")
            } catch let error as SerialTransportError {
                try expectEqual(
                    error,
                    .exclusiveAccessFailed(
                        path: terminal.path,
                        code: EBUSY
                    )
                )
            }
        }
    ]
}

// Injects a deterministic two-byte prefix followed by EAGAIN; no data is sent to a device.
private final class PartialWriteFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = false
    private var released = false
    private var output: [UInt8] = []
    private var hasPartialWrite: Bool { lock.withLock { partial } }
    func waitForPartialWrite() async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !hasPartialWrite {
            guard ContinuousClock.now < deadline else { throw TestFailure(description: "partial write did not begin") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    var bytes: [UInt8] { lock.withLock { output } }
    func release() { lock.withLock { released = true } }
    func write(_ descriptor: Int32, _ pointer: UnsafeRawPointer?, _ count: Int) -> Int {
        lock.withLock {
            let bytes = Array(UnsafeRawBufferPointer(start: pointer, count: count))
            if bytes.first == 65 && !partial {
                output.append(contentsOf: bytes.prefix(2))
                partial = true
                return 2
            }
            if bytes.first == 65 && !released { errno = EAGAIN; return -1 }
            output.append(contentsOf: bytes)
            return count
        }
    }
}
