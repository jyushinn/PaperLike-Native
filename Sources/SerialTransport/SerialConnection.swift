import Darwin
import Dispatch
import Foundation

public protocol SerialConnection: Sendable {
    var path: String { get }
    var incomingBytes: AsyncThrowingStream<[UInt8], Error> { get }

    func open() async throws
    func close() async
    func write(_ bytes: [UInt8]) async throws
}

public enum SerialTransportError: Error, Equatable, Sendable {
    case openFailed(path: String, code: Int32)
    case configureFailed(path: String, code: Int32)
    case exclusiveAccessFailed(path: String, code: Int32)
    case notOpen
    case writeFailed(code: Int32)
    case readFailed(code: Int32)
}

public actor POSIXSerialConnection: SerialConnection {
    public nonisolated let path: String
    public nonisolated let incomingBytes: AsyncThrowingStream<[UInt8], Error>

    private nonisolated let continuation:
        AsyncThrowingStream<[UInt8], Error>.Continuation
    private nonisolated let makeExclusive: @Sendable (Int32) -> Int32
    private nonisolated let writeBytes: @Sendable (Int32, UnsafeRawPointer?, Int) -> Int
    private var descriptor: Int32 = -1
    private var descriptorGeneration = UUID()
    private var isWriting = false
    private var readSource: DispatchSourceRead?

    public init(
        path: String,
        makeExclusive: @escaping @Sendable (Int32) -> Int32 = {
            ioctl($0, TIOCEXCL)
        },
        writeBytes: @escaping @Sendable (Int32, UnsafeRawPointer?, Int) -> Int = { Darwin.write($0, $1, $2) }
    ) {
        self.path = path
        self.makeExclusive = makeExclusive
        self.writeBytes = writeBytes
        let pair = AsyncThrowingStream<[UInt8], Error>.makeStream()
        incomingBytes = pair.stream
        continuation = pair.continuation
    }

    isolated deinit {
        if let readSource {
            readSource.cancel()
        } else if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        continuation.finish()
    }

    public func open() async throws {
        guard descriptor < 0 else {
            return
        }

        let openedDescriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard openedDescriptor >= 0 else {
            throw SerialTransportError.openFailed(path: path, code: errno)
        }

        do {
            try configure(openedDescriptor)
            guard makeExclusive(openedDescriptor) == 0 else {
                throw SerialTransportError.exclusiveAccessFailed(
                    path: path,
                    code: errno
                )
            }
        } catch {
            Darwin.close(openedDescriptor)
            throw error
        }

        descriptor = openedDescriptor
        descriptorGeneration = UUID()
        let source = DispatchSource.makeReadSource(
            fileDescriptor: openedDescriptor,
            queue: DispatchQueue(label: "com.paperlike.native.serial.read")
        )
        let streamContinuation = continuation
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 512)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(openedDescriptor, $0.baseAddress, $0.count)
            }

            if count > 0 {
                streamContinuation.yield(Array(buffer.prefix(count)))
            } else if count == 0 {
                streamContinuation.finish()
            } else if errno != EAGAIN, errno != EWOULDBLOCK {
                streamContinuation.finish(
                    throwing: SerialTransportError.readFailed(code: errno)
                )
            }
        }
        source.setCancelHandler {
            Darwin.close(openedDescriptor)
        }
        readSource = source
        source.activate()
    }

    public func close() async {
        guard descriptor >= 0 else {
            return
        }

        let closingDescriptor = descriptor
        descriptor = -1
        descriptorGeneration = UUID()
        let source = readSource
        readSource = nil
        if let source {
            await withCheckedContinuation { waiter in
                source.setCancelHandler {
                    Darwin.close(closingDescriptor)
                    waiter.resume()
                }
                source.cancel()
            }
        }
        continuation.finish()
    }

    public func write(_ bytes: [UInt8]) async throws {
        try Task.checkCancellation()
        guard descriptor >= 0 else {
            throw SerialTransportError.notOpen
        }

        let writeDescriptor = descriptor
        let generation = descriptorGeneration
        let deadline = ContinuousClock.now + .seconds(2)
        // Avoid busy-waiting when the low-rate serial link applies backpressure.
        while isWriting {
            try Task.checkCancellation()
            guard descriptor == writeDescriptor, descriptorGeneration == generation else { throw SerialTransportError.notOpen }
            guard ContinuousClock.now < deadline else { throw SerialTransportError.writeFailed(code: ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(2))
        }
        try Task.checkCancellation()
        guard descriptor == writeDescriptor, descriptorGeneration == generation else { throw SerialTransportError.notOpen }
        isWriting = true
        defer { isWriting = false }
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            guard descriptor == writeDescriptor, descriptorGeneration == generation else { throw SerialTransportError.notOpen }
            guard ContinuousClock.now < deadline else {
                throw SerialTransportError.writeFailed(code: ETIMEDOUT)
            }
            let count = bytes.withUnsafeBytes {
                writeBytes(
                    descriptor,
                    $0.baseAddress?.advanced(by: offset),
                    $0.count - offset
                )
            }

            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                try await Task.sleep(for: .milliseconds(2))
            } else {
                throw SerialTransportError.writeFailed(code: count == 0 ? EIO : errno)
            }
        }
    }

    private func configure(_ descriptor: Int32) throws {
        var options = termios()
        guard tcgetattr(descriptor, &options) == 0 else {
            throw SerialTransportError.configureFailed(path: path, code: errno)
        }

        cfmakeraw(&options)
        options.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)

        guard cfsetspeed(&options, speed_t(B115200)) == 0,
              tcsetattr(descriptor, TCSANOW, &options) == 0 else {
            throw SerialTransportError.configureFailed(path: path, code: errno)
        }
    }
}
