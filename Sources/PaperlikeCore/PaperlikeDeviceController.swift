import Foundation
import PaperlikeProtocol
import SerialTransport

public enum PaperlikeDeviceError: Error, Equatable, Sendable, LocalizedError {
    case notConnected
    case busy
    case timedOut
    case cancelled
    case unsupported(identifier: String)
    case unsupportedFeature(name: String)
    case invalidValue
    case connectionLost
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .notConnected, .connectionLost: "控制连接已断开，请重新连接。"
        case .busy: "设备正在执行其他指令，请稍候。"
        case .timedOut: "设备未在规定时间内返回确认。"
        case .cancelled: "操作已取消或连接已改变。"
        case let .unsupported(identifier): "设备型号不支持：\(identifier)。"
        case let .unsupportedFeature(name): "当前设备不支持\(name)。"
        case .invalidValue: "设备参数超出支持范围。"
        case .verificationFailed: "设备读回值与目标不一致。"
        }
    }
}

public enum CommandDelivery: Equatable, Sendable {
    case acknowledged
    case sentWithoutAcknowledgement
}

public actor PaperlikeDeviceController {
    public nonisolated let events: AsyncStream<ConnectionState>

    private struct PendingRequest {
        let token: UUID
        let responseCommand: UInt8
        let parameter: UInt8?
        let continuation: CheckedContinuation<PaperlikeResponse, Error>
        var writeCompleted = false
        var earlyResponse: PaperlikeResponse?
    }

    private nonisolated let eventContinuation:
        AsyncStream<ConnectionState>.Continuation
    private let requestTimeout: Duration
    private let keepAliveInterval: Duration
    private let connectionFactory:
        @Sendable (String) -> any SerialConnection

    private var state: ConnectionState = .disconnected
    private var connection: (any SerialConnection)?
    private var decoder = ResponseStreamDecoder()
    private var readTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var pending: PendingRequest?
    private var connectionGeneration = UUID()

    public init(
        requestTimeout: Duration = .seconds(1),
        keepAliveInterval: Duration = .seconds(2),
        connectionFactory: @escaping @Sendable (String) -> any SerialConnection = {
            POSIXSerialConnection(path: $0)
        }
    ) {
        self.requestTimeout = requestTimeout
        self.keepAliveInterval = keepAliveInterval
        self.connectionFactory = connectionFactory
        let pair = AsyncStream<ConnectionState>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
        pair.continuation.yield(.disconnected)
    }

    deinit {
        readTask?.cancel()
        timeoutTask?.cancel()
        writeTask?.cancel()
        keepAliveTask?.cancel()
        eventContinuation.finish()
    }

    public func currentState() -> ConnectionState {
        state
    }

    public func connect(path: String) async throws {
        await disconnect(emitState: false)
        connectionGeneration = UUID()
        publish(.connecting(path: path))

        let serial = connectionFactory(path)
        connection = serial

        do {
            try await serial.open()
            startReading(from: serial)

            let mcu = try await query(0x10).field3
            let family = try await query(0x13).field3
            guard let profile = PaperlikeDeviceProfile(
                mcuVersion: mcu,
                familyIdentifier: family
            ) else {
                let identifier = String(
                    format: "MCU %02X / 型号 %02X",
                    mcu,
                    family
                )
                publish(.unsupported(identifier: identifier))
                await disconnectTransport()
                throw PaperlikeDeviceError.unsupported(
                    identifier: identifier
                )
            }

            let threshold = try await query(0x01).field3
            let modeValue = try await query(0x02).field3
            var frontLightMode: UInt8 = 0
            var brightness: UInt8 = 0
            var temperature: UInt8 = 0
            if profile.hasFrontLight {
                frontLightMode = try await query(0x07).field3
                brightness = try await query(0x09).field3
                temperature = try await query(0x08).field3
            }
            guard let mode = DisplayMode(queryValue: Int(modeValue)),
                  (1...9).contains(threshold), (0...3).contains(frontLightMode),
                  (0...100).contains(brightness), (0...100).contains(temperature) else {
                throw PaperlikeDeviceError.invalidValue
            }
            try await writeKeepAlive(to: serial)

            let deviceState = DeviceState(
                profile: profile,
                mode: mode,
                threshold: Int(threshold),
                speed: nil,
                frontLightMode: Int(frontLightMode),
                brightness: Int(brightness),
                temperature: Int(temperature)
            )
            publish(
                .connected(
                    name: profile.displayName,
                    state: deviceState
                )
            )
            startKeepAlive(generation: connectionGeneration)
        } catch {
            if case .unsupported = state {
                throw error
            }
            await disconnectTransport()
            publish(.failed(message: Self.message(for: error)))
            throw error
        }
    }

    public func disconnect() async {
        await disconnect(emitState: true)
    }

    public func setMode(_ mode: DisplayMode) async throws {
        try await mutate(
            command: .mode,
            value: mode.rawValue
        ) {
            $0.mode = mode
        }
    }

    public func setThreshold(_ value: Int) async throws {
        guard (1...9).contains(value) else { throw PaperlikeDeviceError.invalidValue }
        try await mutate(
            command: .threshold,
            value: value
        ) {
            $0.threshold = value
        }
    }

    public func setSpeed(_ value: Int) async throws {
        guard (1...5).contains(value) else {
            throw PaperlikeDeviceError.invalidValue
        }
        try await mutate(
            command: .speed,
            value: value
        ) {
            $0.speed = value
        }
    }

    public func setFrontLightMode(_ value: Int) async throws {
        try requireFrontLight()
        guard (0...3).contains(value) else { throw PaperlikeDeviceError.invalidValue }
        try await mutate(
            command: .frontLightMode,
            value: value
        ) {
            $0.frontLightMode = value
        }
    }

    public func setBrightness(_ value: Int) async throws {
        try requireFrontLight()
        guard (0...100).contains(value) else { throw PaperlikeDeviceError.invalidValue }
        try await mutate(
            command: .frontLightBrightness,
            value: value
        ) {
            $0.brightness = value
        }
    }

    public func setTemperature(_ value: Int) async throws {
        try requireFrontLight()
        guard (0...100).contains(value) else { throw PaperlikeDeviceError.invalidValue }
        try await mutate(
            command: .frontLightTemperature,
            value: value
        ) {
            $0.temperature = value
        }
    }

    /// Reads the supported query registers, not our optimistic write cache.
    public func verifyDisplayConfiguration() async throws -> Bool {
        guard case let .connected(_, expected) = state else { throw PaperlikeDeviceError.notConnected }
        let generation = connectionGeneration
        let modeValue = try await query(0x02, timeout: .milliseconds(500)).field3
        try Task.checkCancellation()
        let threshold = Int(try await query(0x01, timeout: .milliseconds(500)).field3)
        guard generation == connectionGeneration else { throw PaperlikeDeviceError.cancelled }
        guard let mode = DisplayMode(queryValue: Int(modeValue)), (1...9).contains(threshold) else {
            throw PaperlikeDeviceError.invalidValue
        }
        guard case let .connected(name, latest) = state else { throw PaperlikeDeviceError.connectionLost }
        var actual = latest
        actual.mode = mode
        actual.threshold = threshold
        publish(.connected(name: name, state: actual))
        return mode == expected.mode && threshold == expected.threshold
    }

    /// Reads the supported query registers, not our optimistic write cache.
    public func readLightingConfiguration() async throws -> LightingConfiguration {
        try requireFrontLight()
        let generation = connectionGeneration
        var values: [Int] = []
        for parameter: UInt8 in [0x07, 0x09, 0x08] {
            try Task.checkCancellation()
            let response = try await query(parameter, timeout: .milliseconds(500))
            guard generation == connectionGeneration else { throw PaperlikeDeviceError.cancelled }
            values.append(Int(response.field3))
        }
        guard (0...3).contains(values[0]), (0...100).contains(values[1]),
              (0...100).contains(values[2]) else { throw PaperlikeDeviceError.invalidValue }
        guard case let .connected(name, latest) = state else { throw PaperlikeDeviceError.connectionLost }
        var actual = latest
        actual.frontLightMode = values[0]
        actual.brightness = values[1]
        actual.temperature = values[2]
        publish(.connected(name: name, state: actual))
        return LightingConfiguration(frontLightMode: values[0], brightness: values[1], temperature: values[2])
    }

    public func refresh() async throws {
        do {
            _ = try await request(
                command: .refresh,
                parameter: 0,
                expectedParameter: nil,
                timeout: .milliseconds(300)
            )
        } catch PaperlikeDeviceError.timedOut {
            return
        }
    }

    public func syncRealTimeClock() async throws -> CommandDelivery {
        do {
            _ = try await request(
                command: .realTimeClock,
                parameter: 0,
                expectedParameter: nil,
                timeout: .milliseconds(300)
            )
            return .acknowledged
        } catch PaperlikeDeviceError.timedOut {
            return .sentWithoutAcknowledgement
        }
    }

    private func requireFrontLight() throws {
        guard case let .connected(_, deviceState) = state else {
            throw PaperlikeDeviceError.notConnected
        }
        guard deviceState.profile.hasFrontLight else {
            throw PaperlikeDeviceError.unsupportedFeature(name: "前光")
        }
    }

    private func mutate(
        command: PaperlikeCommand,
        value: Int,
        update: (inout DeviceState) -> Void
    ) async throws {
        guard case .connected = state else {
            throw PaperlikeDeviceError.notConnected
        }
        let generation = connectionGeneration

        do {
            _ = try await request(
                command: command,
                parameter: value,
                expectedParameter: nil,
                timeout: .milliseconds(300)
            )
        } catch PaperlikeDeviceError.timedOut {
            // 此固件的状态写入 ACK 并不稳定；命令只发送一次，不自动重试。
        }
        try await Task.sleep(for: .milliseconds(220))
        guard generation == connectionGeneration else {
            throw PaperlikeDeviceError.cancelled
        }
        guard case let .connected(name, latest) = state else {
            throw PaperlikeDeviceError.connectionLost
        }
        var updated = latest
        update(&updated)
        publish(.connected(name: name, state: updated))
    }

    private func query(_ parameter: UInt8, timeout: Duration? = nil) async throws -> PaperlikeResponse {
        let generation = connectionGeneration
        var lastError: Error = PaperlikeDeviceError.timedOut
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard generation == connectionGeneration else { throw PaperlikeDeviceError.cancelled }
            do {
                let response = try await request(
                    command: .query,
                    parameter: Int(parameter),
                    expectedParameter: parameter,
                    timeout: timeout
                )
                guard generation == connectionGeneration else { throw PaperlikeDeviceError.cancelled }
                return response
            } catch PaperlikeDeviceError.timedOut {
                lastError = PaperlikeDeviceError.timedOut
            }
        }
        throw lastError
    }

    private func writeKeepAlive(
        to serial: any SerialConnection
    ) async throws {
        let bytes = try PaperlikeRequest(
            command: .keepAlive,
            parameter: 1
        ).encoded()
        try await serial.write(bytes)
    }

    private func startKeepAlive(generation: UUID) {
        keepAliveTask?.cancel()
        let interval = keepAliveInterval
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.sendPeriodicKeepAlive(generation: generation)
            }
        }
    }

    private func sendPeriodicKeepAlive(generation: UUID) async {
        guard generation == connectionGeneration,
              case .connected = state,
              pending == nil,
              let connection
        else {
            return
        }
        do {
            try await writeKeepAlive(to: connection)
        } catch {
            guard generation == connectionGeneration else { return }
            await connectionEnded()
        }
    }

    private func request(
        command: PaperlikeCommand,
        parameter: Int,
        expectedParameter: UInt8?,
        timeout: Duration? = nil
    ) async throws -> PaperlikeResponse {
        guard pending == nil else {
            throw PaperlikeDeviceError.busy
        }
        guard let connection else {
            throw PaperlikeDeviceError.notConnected
        }

        let bytes = try PaperlikeRequest(
            command: command,
            parameter: parameter
        ).encoded()
        let token = UUID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = PendingRequest(
                    token: token,
                    responseCommand: command.rawValue,
                    parameter: expectedParameter,
                    continuation: continuation
                )
                writeTask = Task {
                    do {
                        try await connection.write(bytes)
                        guard var request = pending, request.token == token else { return }
                        request.writeCompleted = true
                        pending = request
                        if let response = request.earlyResponse {
                            completeRequest(response)
                            return
                        }
                        // Only an entirely written frame can become "sent, no ACK".
                        timeoutTask = Task {
                            do {
                                try await Task.sleep(for: timeout ?? requestTimeout)
                                timeoutRequest(token: token)
                            } catch {}
                        }
                    } catch {
                        failRequest(token: token, error: error)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.failRequest(
                    token: token,
                    error: PaperlikeDeviceError.cancelled
                )
            }
        }
    }

    private func startReading(from serial: any SerialConnection) {
        readTask?.cancel()
        readTask = Task { [weak self] in
            do {
                for try await bytes in serial.incomingBytes {
                    guard let self else { return }
                    await self.receive(bytes)
                }
                guard let self, !Task.isCancelled else { return }
                await self.connectionEnded()
            } catch {
                guard let self, !Task.isCancelled else { return }
                await self.connectionEnded()
            }
        }
    }

    private func receive(_ bytes: [UInt8]) {
        do {
            for response in try decoder.append(bytes) {
                if response.command == 0x01 {
                    applyThresholdEvent(value: Int(response.field1))
                    continue
                }
                guard let pending,
                      response.command == 0xF0,
                      response.field1 == pending.responseCommand,
                      pending.parameter == nil
                        || response.field2 == pending.parameter
                else {
                    continue
                }
                if !pending.writeCompleted {
                    self.pending?.earlyResponse = response
                    continue
                }
                completeRequest(response)
            }
        } catch {
            if let token = pending?.token {
                failRequest(token: token, error: error)
            }
        }
    }

    private func timeoutRequest(token: UUID) {
        failRequest(token: token, error: PaperlikeDeviceError.timedOut)
    }

    private func completeRequest(_ response: PaperlikeResponse) {
        guard let pending, pending.writeCompleted else { return }
        self.pending = nil
        writeTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        pending.continuation.resume(returning: response)
    }

    private func applyThresholdEvent(value: Int) {
        guard (1...9).contains(value), case let .connected(name, current) = state else {
            return
        }
        var updated = current
        updated.threshold = value
        publish(.connected(name: name, state: updated))
    }

    private func failRequest(token: UUID, error: Error) {
        guard pending?.token == token else {
            return
        }
        let continuation = pending?.continuation
        pending = nil
        writeTask?.cancel()
        writeTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(throwing: error)
    }

    private func connectionEnded() async {
        if let token = pending?.token {
            failRequest(
                token: token,
                error: PaperlikeDeviceError.connectionLost
            )
        }
        await disconnectTransport()
        if case .connected = state {
            publish(.failed(message: "与显示器的连接已中断。"))
        }
    }

    private func disconnect(emitState: Bool) async {
        connectionGeneration = UUID()
        if let token = pending?.token {
            failRequest(
                token: token,
                error: PaperlikeDeviceError.cancelled
            )
        }
        await disconnectTransport()
        if emitState {
            publish(.disconnected)
        }
    }

    private func disconnectTransport() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        readTask?.cancel()
        readTask = nil
        if let connection {
            await connection.close()
        }
        connection = nil
        decoder = ResponseStreamDecoder()
    }

    private func publish(_ newState: ConnectionState) {
        state = newState
        eventContinuation.yield(newState)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case PaperlikeDeviceError.timedOut:
            "设备响应超时，请重新连接。"
        case PaperlikeDeviceError.connectionLost:
            "与显示器的连接已中断。"
        default:
            "无法连接显示器。"
        }
    }
}
