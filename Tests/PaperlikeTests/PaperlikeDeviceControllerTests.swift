import Foundation
import PaperlikeCore
import SerialTransport

private actor FakeSerialConnection: SerialConnection {
    nonisolated let path = "/dev/cu.usbserial-test"
    nonisolated let incomingBytes: AsyncThrowingStream<[UInt8], Error>

    private nonisolated let continuation:
        AsyncThrowingStream<[UInt8], Error>.Continuation
    private let queryOverrides: [UInt8: UInt8]
    private let shouldRespond: Bool
    private let mcuValue: UInt8
    private let familyValue: UInt8
    private let ignoredCommands: Set<UInt8>
    private let delayedWriteFailure: Bool
    private let earlyAcknowledgement: Bool
    private let delayedWriteSuccess: Bool
    private let dropQueryAfterFrontLight: Bool
    private let droppedQueryCount: Int
    private var remainingDroppedQueries = 0
    private var speedWriteCompleted = false
    private var writes: [[UInt8]] = []
    private var closed = false

    init(
        queryOverrides: [UInt8: UInt8] = [:],
        shouldRespond: Bool = true,
        mcuValue: UInt8 = 0x30,
        familyValue: UInt8 = 0x01,
        ignoredCommands: Set<UInt8> = [],
        delayedWriteFailure: Bool = false,
        earlyAcknowledgement: Bool = false,
        delayedWriteSuccess: Bool = false,
        dropQueryAfterFrontLight: Bool = false,
        droppedQueryCount: Int = 1
    ) {
        self.droppedQueryCount = droppedQueryCount
        self.dropQueryAfterFrontLight = dropQueryAfterFrontLight
        self.queryOverrides = queryOverrides
        self.shouldRespond = shouldRespond
        self.mcuValue = mcuValue
        self.familyValue = familyValue
        self.ignoredCommands = ignoredCommands
        self.delayedWriteFailure = delayedWriteFailure
        self.earlyAcknowledgement = earlyAcknowledgement
        self.delayedWriteSuccess = delayedWriteSuccess
        let pair = AsyncThrowingStream<[UInt8], Error>.makeStream()
        incomingBytes = pair.stream
        continuation = pair.continuation
    }

    func open() async throws {}

    func close() async {
        closed = true
        continuation.finish()
    }

    func write(_ bytes: [UInt8]) async throws {
        writes.append(bytes)
        guard shouldRespond else { return }

        let command = try parseByte(bytes[4..<6])
        let parameter = try parseByte(bytes[6..<8])
        if command == 0x07 && dropQueryAfterFrontLight { remainingDroppedQueries = droppedQueryCount }
        if command == 0x0A && remainingDroppedQueries > 0 { remainingDroppedQueries -= 1; return }
        if (delayedWriteFailure || delayedWriteSuccess) && command == 0x04 {
            if earlyAcknowledgement {
                continuation.yield(Array(String(format: "5FF5F0%02X000000000000A0FA", command).utf8))
            }
            try await Task.sleep(for: .milliseconds(650))
            if delayedWriteFailure { throw SerialTransportError.writeFailed(code: 5) }
            speedWriteCompleted = true
        }
        guard !ignoredCommands.contains(command) else { return }
        let value: UInt8
        if command == 0x0A {
            value = queryOverrides[parameter] ?? [
                0x10: mcuValue,
                0x13: familyValue,
                0x01: 0x01,
                0x02: 0x02,
                0x07: 0x03,
                0x09: 0x27,
                0x08: 0x56
            ][parameter] ?? 0
        } else {
            value = 0
        }
        let echoedParameter = command == 0x0A ? parameter : 0
        let response = String(
            format: "5FF5F0%02X%02X%02X00000000A0FA",
            command,
            echoedParameter,
            value
        )
        continuation.yield(Array(response.utf8))
        if command == 0x02 {
            let threshold: UInt8 = parameter == 0x07 ? 5
                : parameter == 0x02 ? 1 : 2
            let update = String(
                format: "5FF501%02X000000000000A0FA",
                threshold
            )
            continuation.yield(Array(update.utf8))
        }
    }

    func sendThresholdEvent(_ value: UInt8) {
        continuation.yield(Array(String(format: "5FF501%02X000000000000A0FA", value).utf8))
    }

    func recordedRequests() -> [String] {
        writes.map { String(decoding: $0, as: UTF8.self) }
    }

    func isClosed() -> Bool {
        closed
    }

    func completedSpeedWrite() -> Bool { speedWriteCompleted }

    func finishIncoming() {
        continuation.finish()
    }
}

private func parseByte(_ bytes: ArraySlice<UInt8>) throws -> UInt8 {
    guard let value = UInt8(String(decoding: bytes, as: UTF8.self), radix: 16)
    else {
        throw TestFailure(description: "invalid request")
    }
    return value
}

func paperlikeDeviceControllerTests() -> [TestCase] {
    [
        TestCase("PaperlikeDeviceControllerTests.decodesWebQueryWithoutChangingWriteValue") {
            // Actual color-device capture: write 02 06, query 0A 02 returns 01.
            for value: UInt8 in [1, 6] {
                let serial = FakeSerialConnection(queryOverrides: [0x02: value])
                let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
                try await controller.connect(path: serial.path)
                guard case let .connected(_, initial) = await controller.currentState() else { throw TestFailure(description: "disconnected") }
                try expectEqual(initial.mode, .web)
                try await controller.setMode(.text)
                let matched = try await controller.verifyDisplayConfiguration()
                try expect(!matched, "readback must correct the optimistic text mode")
                guard case let .connected(_, actual) = await controller.currentState() else { throw TestFailure(description: "disconnected") }
                try expectEqual(actual.mode, .web)
                try await controller.setMode(.web)
                let requests = await serial.recordedRequests()
                await controller.disconnect()
                try expect(requests.contains("5FF50206000000000000A0FA"), "web writes must retain command value 6")
                try expect(!requests.contains("5FF50201000000000000A0FA"), "query value 1 must never become a write value")
            }
        },
        TestCase("PaperlikeDeviceControllerTests.retriesDroppedReadbackAfterFrontLightChange") {
            for displayRead in [true, false] {
                let serial = FakeSerialConnection(dropQueryAfterFrontLight: true)
                let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
                try await controller.connect(path: serial.path)
                try await controller.setFrontLightMode(0)
                if displayRead { _ = try await controller.verifyDisplayConfiguration() }
                else { _ = try await controller.readLightingConfiguration() }
                let requests = await serial.recordedRequests()
                await controller.disconnect()
                let query = displayRead ? "5FF50A02000000000000A0FA" : "5FF50A07000000000000A0FA"
                try expectEqual(requests.filter { $0 == query }.count, 3)
                try expectEqual(requests.filter { $0 == "5FF50700000000000000A0FA" }.count, 1)
            }
        },
        TestCase("PaperlikeDeviceControllerTests.readbackRetriesAreBoundedAndCancellable") {
            for cancel in [false, true] {
                let serial = FakeSerialConnection(dropQueryAfterFrontLight: true, droppedQueryCount: 10)
                let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
                try await controller.connect(path: serial.path)
                try await controller.setFrontLightMode(0)
                let read = Task { try await controller.verifyDisplayConfiguration() }
                if cancel {
                    // Wait for an actual query, not a guessed timing interval.
                    let deadline = ContinuousClock.now + .seconds(2)
                    while (await serial.recordedRequests()).filter({ $0 == "5FF50A02000000000000A0FA" }).count < 2 {
                        try expect(ContinuousClock.now < deadline, "read query not sent")
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    read.cancel()
                }
                do { _ = try await read.value; throw TestFailure(description: "missing query response accepted") }
                catch PaperlikeDeviceError.timedOut { try expect(!cancel, "cancellation became timeout") }
                catch PaperlikeDeviceError.cancelled { try expect(cancel, "uncancelled query aborted") }
                catch is CancellationError { try expect(cancel, "uncancelled query aborted") }
                let requests = await serial.recordedRequests()
                await controller.disconnect()
                try expectEqual(requests.filter { $0 == "5FF50A02000000000000A0FA" }.count, cancel ? 2 : 4)
                try expectEqual(requests.filter { $0 == "5FF50700000000000000A0FA" }.count, 1)
            }
        },
        TestCase("PaperlikeDeviceControllerTests.rejectsOutOfRangeWritesBeforeSerialIO") {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
            try await controller.connect(path: serial.path)
            let initial = await controller.currentState()
            for (control, invalid) in [("threshold", [0, 10, -1, 255, 256, Int.min, Int.max]), ("frontLightMode", [-1, 4, 255, 256]), ("brightness", [-1, 101, 255, 256]), ("temperature", [-1, 101, 255, 256])] {
                for value in invalid {
                    do {
                        switch control {
                        case "threshold": try await controller.setThreshold(value)
                        case "frontLightMode": try await controller.setFrontLightMode(value)
                        case "brightness": try await controller.setBrightness(value)
                        default: try await controller.setTemperature(value)
                        }
                        throw TestFailure(description: "\(control) accepted \(value)")
                    } catch PaperlikeDeviceError.invalidValue {}
                }
            }
            let final = await controller.currentState()
            let writes = await serial.recordedRequests()
            await controller.disconnect()
            try expectEqual(final, initial)
            try expect(!writes.contains(where: { ["5FF501", "5FF507", "5FF508", "5FF509"].contains(where: $0.hasPrefix) }), "invalid values must not reach hardware")
        },
        TestCase("PaperlikeDeviceController.lightingReadbackCorrectsPublishedState") {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
            try await controller.connect(path: serial.path)
            try await controller.setBrightness(80)
            let actual = try await controller.readLightingConfiguration()
            guard case let .connected(_, state) = await controller.currentState() else { throw TestFailure(description: "disconnected") }
            await controller.disconnect()
            try expectEqual(state.brightness, actual.brightness)
            try expectEqual(state.frontLightMode, actual.frontLightMode)
            try expectEqual(state.temperature, actual.temperature)
        },
        TestCase("PaperlikeDeviceController.rejectsInvalidHandshakeRegisters") {
            for parameter: UInt8 in [0x01, 0x02, 0x07, 0x09, 0x08] {
                let serial = FakeSerialConnection(queryOverrides: [parameter: 255])
                let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
                do { try await controller.connect(path: serial.path); await controller.disconnect(); throw TestFailure(description: "invalid register \(parameter) accepted") }
                catch PaperlikeDeviceError.invalidValue { }
            }
        },
        TestCase("PaperlikeDeviceController.ignoresInvalidThresholdEvent") {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
            try await controller.connect(path: serial.path)
            await serial.sendThresholdEvent(255)
            // A following query response is consumed after the preceding event.
            _ = try await controller.readLightingConfiguration()
            guard case let .connected(_, state) = await controller.currentState() else { throw TestFailure(description: "disconnected") }
            await controller.disconnect()
            try expectEqual(state.threshold, 1)
        },
        TestCase("PaperlikeDeviceControllerTests.earlyAcknowledgementWaitsForSuccessfulWrite") {
            let serial = FakeSerialConnection(earlyAcknowledgement: true, delayedWriteSuccess: true)
            let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
            try await controller.connect(path: serial.path)
            try await controller.setSpeed(5)
            let completed = await serial.completedSpeedWrite()
            try expect(completed, "matching early ACK must not cancel the frame writer")
            await controller.disconnect()
        },
        TestCase("PaperlikeDeviceControllerTests.cancelsWhileHoldingEarlyAcknowledgement") {
            let serial = FakeSerialConnection(earlyAcknowledgement: true, delayedWriteSuccess: true)
            let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
            try await controller.connect(path: serial.path)
            let operation = Task { try await controller.setSpeed(5) }
            try await Task.sleep(for: .milliseconds(50))
            operation.cancel()
            do {
                try await operation.value
                throw TestFailure(description: "cancelled write completed")
            } catch is CancellationError {} catch PaperlikeDeviceError.cancelled {}
            guard case let .connected(_, state) = await controller.currentState() else {
                throw TestFailure(description: "controller disconnected")
            }
            try expectEqual(state.speed, nil)
            let completed = await serial.completedSpeedWrite()
            try expect(!completed, "cancel propagates to held-ACK frame writer")
            await controller.disconnect()
        },
        TestCase("PaperlikeDeviceControllerTests.earlyAcknowledgementCannotHideWriteFailure") {
            let serial = FakeSerialConnection(delayedWriteFailure: true, earlyAcknowledgement: true)
            let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
            try await controller.connect(path: serial.path)
            do {
                try await controller.setSpeed(5)
                throw TestFailure(description: "an early ACK hid an incomplete write")
            } catch let error as SerialTransportError {
                try expectEqual(error, .writeFailed(code: 5))
            }
            guard case let .connected(_, state) = await controller.currentState() else {
                throw TestFailure(description: "controller disconnected")
            }
            try expectEqual(state.speed, nil)
            await controller.disconnect()
        },
        TestCase("DisplaySliderQueue.keepsFinalValuePerControlAndClearsOnDisconnect") {
            var queue = DisplaySliderQueue()
            queue.submit(.threshold(2)); queue.submit(.threshold(8))
            queue.submit(.speed(2)); queue.submit(.speed(5))
            try expectEqual(queue.next(), .threshold(8))
            try expectEqual(queue.next(), .speed(5))
            try expectEqual(queue.next(), nil)
            queue.submit(.threshold(4)); queue.removeAll()
            try expectEqual(queue.next(), nil)
        },
        TestCase("PaperlikeDeviceControllerTests.doesNotClaimSentBeforeWriteCompletes") {
            let serial = FakeSerialConnection(delayedWriteFailure: true)
            let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
            try await controller.connect(path: serial.path)
            do {
                try await controller.setSpeed(5)
                throw TestFailure(description: "an incomplete transport write was claimed as sent")
            } catch let error as SerialTransportError {
                try expectEqual(error, .writeFailed(code: 5))
            }
            await controller.disconnect()
        },
        TestCase("PaperlikeDeviceControllerTests.readbackCorrectsOptimisticDisplayValue") {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
            try await controller.connect(path: serial.path)
            try await controller.setThreshold(8)
            let matched = try await controller.verifyDisplayConfiguration()
            try expect(!matched, "a sent value is not a confirmed device value")
            guard case let .connected(_, state) = await controller.currentState() else {
                throw TestFailure(description: "controller disconnected")
            }
            try expectEqual(state.threshold, 1)
            await controller.disconnect()
        },
        TestCase("PaperlikeDeviceControllerTests.readsActualLightingInsteadOfDraft") {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
            try await controller.connect(path: serial.path)
            try await controller.setBrightness(80)
            let actual = try await controller.readLightingConfiguration()
            try expectEqual(actual, LightingConfiguration(frontLightMode: 3, brightness: 39, temperature: 86))
            await controller.disconnect()
        },
        TestCase("PaperlikeDeviceControllerTests.rejectsUnverifiedSpeed") {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(connectionFactory: { _ in serial })
            try await controller.connect(path: serial.path)
            do {
                try await controller.setSpeed(6)
                throw TestFailure(description: "unverified speed must not be sent")
            } catch let error as PaperlikeDeviceError {
                try expectEqual(error, .invalidValue)
            }
            let requests = await serial.recordedRequests()
            try expect(!requests.contains(where: { $0.hasPrefix("5FF50406") }), "no unsafe write")
            await controller.disconnect()
        },
        TestCase(
            "PaperlikeDeviceProfileTests.identifiesSupported13KModels"
        ) {
            let color = PaperlikeDeviceProfile(
                mcuVersion: 0x30,
                familyIdentifier: 0x01
            )
            try expectEqual(color?.panelKind, .color)
            try expectEqual(color?.hasFrontLight, true)
            try expectEqual(
                color?.displayName,
                "PaperLike 13.3K 彩色版（有前光）"
            )
            try expectEqual(
                color?.verificationText,
                "已在此识别码的彩色版实机验证"
            )
            let unverifiedColor = PaperlikeDeviceProfile(
                mcuVersion: 0x31,
                familyIdentifier: 0x01
            )
            try expectEqual(
                unverifiedColor?.verificationText,
                "协议兼容，未实机验证"
            )

            let litMonochrome = PaperlikeDeviceProfile(
                mcuVersion: 0x31,
                familyIdentifier: 0x02
            )
            try expectEqual(litMonochrome?.panelKind, .monochrome)
            try expectEqual(litMonochrome?.hasFrontLight, true)
            try expectEqual(
                litMonochrome?.displayName,
                "PaperLike 13.3K 黑白版（有前光）"
            )

            let unlitMonochrome = PaperlikeDeviceProfile(
                mcuVersion: 0x10,
                familyIdentifier: 0x02
            )
            try expectEqual(unlitMonochrome?.panelKind, .monochrome)
            try expectEqual(unlitMonochrome?.hasFrontLight, false)
            try expectEqual(
                unlitMonochrome?.displayName,
                "PaperLike 13.3K 黑白版（无前光）"
            )
        },
        TestCase(
            "PaperlikeDeviceProfileTests.rejectsUnsupportedIdentifiers"
        ) {
            try expectEqual(
                PaperlikeDeviceProfile(
                    mcuVersion: 0x22,
                    familyIdentifier: 0x01
                ),
                nil
            )
            try expectEqual(
                PaperlikeDeviceProfile(
                    mcuVersion: 0x30,
                    familyIdentifier: 0x03
                ),
                nil
            )
        },
        TestCase(
            "DeviceStateTests.exposesFrontLightAvailability"
        ) {
            let litProfile = PaperlikeDeviceProfile(
                mcuVersion: 0x30,
                familyIdentifier: 0x02
            )!
            let unlitProfile = PaperlikeDeviceProfile(
                mcuVersion: 0x10,
                familyIdentifier: 0x02
            )!
            let litState = DeviceState(
                profile: litProfile,
                mode: .web,
                threshold: 1,
                speed: nil,
                frontLightMode: 1,
                brightness: 50,
                temperature: 50
            )
            let unlitState = DeviceState(
                profile: unlitProfile,
                mode: .web,
                threshold: 1,
                speed: nil,
                frontLightMode: 0,
                brightness: 0,
                temperature: 0
            )

            try expectEqual(litState.frontLightAvailable, true)
            try expectEqual(unlitState.frontLightAvailable, false)
        },
        TestCase("PaperlikeDeviceControllerTests.connectsAndQueriesState") {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(
                connectionFactory: { _ in serial }
            )

            try await controller.connect(path: serial.path)

            let requests = await serial.recordedRequests()
            try expectEqual(
                requests.map { String($0.dropFirst(4).prefix(4)) },
                [
                    "0A10", "0A13", "0A01", "0A02",
                    "0A07", "0A09", "0A08", "2001"
                ]
            )
            try expectEqual(
                await controller.currentState(),
                .connected(
                    name: "PaperLike 13.3K 彩色版（有前光）",
                    state: DeviceState(
                        profile: PaperlikeDeviceProfile(
                            mcuVersion: 0x30,
                            familyIdentifier: 0x01
                        )!,
                        mode: .text,
                        threshold: 1,
                        speed: nil,
                        frontLightMode: 3,
                        brightness: 39,
                        temperature: 86
                    )
                )
            )
        },
        TestCase(
            "PaperlikeDeviceControllerTests.connectsMonochromeWithFrontLight"
        ) {
            let serial = FakeSerialConnection(
                mcuValue: 0x31,
                familyValue: 0x02
            )
            let controller = PaperlikeDeviceController(
                connectionFactory: { _ in serial }
            )

            try await controller.connect(path: serial.path)

            let requests = await serial.recordedRequests()
            try expectEqual(
                requests.map { String($0.dropFirst(4).prefix(4)) },
                [
                    "0A10", "0A13", "0A01", "0A02",
                    "0A07", "0A09", "0A08", "2001"
                ]
            )
            try expectEqual(
                await controller.currentState(),
                .connected(
                    name: "PaperLike 13.3K 黑白版（有前光）",
                    state: DeviceState(
                        profile: PaperlikeDeviceProfile(
                            mcuVersion: 0x31,
                            familyIdentifier: 0x02
                        )!,
                        mode: .text,
                        threshold: 1,
                        speed: nil,
                        frontLightMode: 3,
                        brightness: 39,
                        temperature: 86
                    )
                )
            )
        },
        TestCase(
            "PaperlikeDeviceControllerTests.connectsMonochromeWithoutFrontLight"
        ) {
            let serial = FakeSerialConnection(
                mcuValue: 0x10,
                familyValue: 0x02
            )
            let controller = PaperlikeDeviceController(
                connectionFactory: { _ in serial }
            )

            try await controller.connect(path: serial.path)

            let requests = await serial.recordedRequests()
            try expectEqual(
                requests.map { String($0.dropFirst(4).prefix(4)) },
                ["0A10", "0A13", "0A01", "0A02", "2001"]
            )
            try expectEqual(
                await controller.currentState(),
                .connected(
                    name: "PaperLike 13.3K 黑白版（无前光）",
                    state: DeviceState(
                        profile: PaperlikeDeviceProfile(
                            mcuVersion: 0x10,
                            familyIdentifier: 0x02
                        )!,
                        mode: .text,
                        threshold: 1,
                        speed: nil,
                        frontLightMode: 0,
                        brightness: 0,
                        temperature: 0
                    )
                )
            )
        },
        TestCase("PaperlikeDeviceControllerTests.setsTextMode") {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(
                connectionFactory: { _ in serial }
            )
            try await controller.connect(path: serial.path)

            try await controller.setMode(.text)

            let requests = await serial.recordedRequests()
            try expectEqual(String(requests.last!.dropFirst(4).prefix(4)), "0202")
        },
        TestCase(
            "PaperlikeDeviceControllerTests.rejectsFrontLightOnUnlitModel"
        ) {
            let serial = FakeSerialConnection(
                mcuValue: 0x10,
                familyValue: 0x02
            )
            let controller = PaperlikeDeviceController(
                connectionFactory: { _ in serial }
            )
            try await controller.connect(path: serial.path)
            let requestCount = await serial.recordedRequests().count

            do {
                try await controller.setFrontLightMode(1)
                throw TestFailure(
                    description: "unlit model accepted front-light mode"
                )
            } catch let error as PaperlikeDeviceError {
                try expectEqual(error, .unsupportedFeature(name: "前光"))
            }
            do {
                try await controller.setBrightness(50)
                throw TestFailure(
                    description: "unlit model accepted brightness"
                )
            } catch let error as PaperlikeDeviceError {
                try expectEqual(error, .unsupportedFeature(name: "前光"))
            }
            do {
                try await controller.setTemperature(50)
                throw TestFailure(
                    description: "unlit model accepted temperature"
                )
            } catch let error as PaperlikeDeviceError {
                try expectEqual(error, .unsupportedFeature(name: "前光"))
            }

            try expectEqual(
                await serial.recordedRequests().count,
                requestCount
            )
        },
        TestCase(
            "PaperlikeDeviceControllerTests.sendsFiveLevelSpeed"
        ) {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(
                connectionFactory: { _ in serial }
            )
            try await controller.connect(path: serial.path)

            try await controller.setSpeed(5)

            try expectEqual(
                await serial.recordedRequests().last,
                "5FF50405000000000000A0FA"
            )
            let state = await controller.currentState()
            guard case let .connected(_, deviceState) = state else {
                throw TestFailure(description: "controller is not connected")
            }
            try expectEqual(deviceState.speed, 5)
        },
        TestCase(
            "PaperlikeDeviceControllerTests.rejectsInvalidSpeed"
        ) {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(
                connectionFactory: { _ in serial }
            )
            try await controller.connect(path: serial.path)
            let requestCount = await serial.recordedRequests().count

            do {
                try await controller.setSpeed(0)
                throw TestFailure(description: "invalid speed was accepted")
            } catch let error as PaperlikeDeviceError {
                try expectEqual(error, .invalidValue)
            }
            try expectEqual(
                await serial.recordedRequests().count,
                requestCount
            )
        },
        TestCase(
            "PaperlikeDeviceControllerTests.syncsRealTimeClock"
        ) {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(
                connectionFactory: { _ in serial }
            )
            try await controller.connect(path: serial.path)

            let result = try await controller.syncRealTimeClock()

            try expectEqual(result, .acknowledged)
            try expectEqual(
                await serial.recordedRequests().last,
                "5FF50500000000000000A0FA"
            )
        },
        TestCase(
            "PaperlikeDeviceControllerTests.reportsUnacknowledgedClockSync"
        ) {
            let serial = FakeSerialConnection(ignoredCommands: [0x05])
            let controller = PaperlikeDeviceController(
                connectionFactory: { _ in serial }
            )
            try await controller.connect(path: serial.path)

            let result = try await controller.syncRealTimeClock()

            try expectEqual(result, .sentWithoutAcknowledgement)
            let clockRequests = await serial.recordedRequests().filter {
                String($0.dropFirst(4).prefix(4)) == "0500"
            }
            try expectEqual(clockRequests.count, 1)
        },
        TestCase("PaperlikeDeviceControllerTests.keepsDisplayAliveUntilDisconnect") {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(
                keepAliveInterval: .milliseconds(20),
                connectionFactory: { _ in serial }
            )
            try await controller.connect(path: serial.path)
            // Wait for the handshake plus two periodic frames. Task scheduling
            // can legitimately take longer than two nominal timer intervals.
            let deadline = ContinuousClock.now + .seconds(1)
            var activeKeepAlives = 0
            while ContinuousClock.now < deadline {
                activeKeepAlives = await serial.recordedRequests().filter {
                    String($0.dropFirst(4).prefix(4)) == "2001"
                }.count
                if activeKeepAlives >= 3 { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            await controller.disconnect()
            try expect(
                activeKeepAlives >= 3,
                "connected controller must send periodic keep-alives within 1 second; got \(activeKeepAlives)"
            )

            let stoppedCount = await serial.recordedRequests().count
            try await Task.sleep(for: .milliseconds(50))
            let finalCount = await serial.recordedRequests().count
            try expectEqual(finalCount, stoppedCount)
        },
        TestCase("PaperlikeDeviceControllerTests.appliesModeThresholdEvent") {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(
                connectionFactory: { _ in serial }
            )
            try await controller.connect(path: serial.path)

            try await controller.setMode(.web)

            try expectEqual(
                await controller.currentState(),
                .connected(
                    name: "PaperLike 13.3K 彩色版（有前光）",
                    state: DeviceState(
                        profile: PaperlikeDeviceProfile(
                            mcuVersion: 0x30,
                            familyIdentifier: 0x01
                        )!,
                        mode: .web,
                        threshold: 2,
                        speed: nil,
                        frontLightMode: 3,
                        brightness: 39,
                        temperature: 86
                    )
                )
            )
        },
        TestCase("HardwareSelfTestPlan.skipsUnreadableSpeed") {
            try expectEqual(
                HardwareSelfTestPlan.speedRoundTrip(from: nil)?.restore,
                nil
            )
            try expectEqual(
                HardwareSelfTestPlan.speedRoundTrip(from: 1)?.alternate,
                2
            )
            try expectEqual(
                HardwareSelfTestPlan.speedRoundTrip(from: 5)?.alternate,
                4
            )
        },
        TestCase("DeviceState.explainsUnreadableSpeed") {
            let state = DeviceState(
                profile: PaperlikeDeviceProfile(
                    mcuVersion: 0x30,
                    familyIdentifier: 0x01
                )!,
                mode: .text,
                threshold: 1,
                speed: nil,
                frontLightMode: 3,
                brightness: 39,
                temperature: 86
            )
            try expectEqual(state.speedDisplayText, "需手动选择")
            var selectedState = state
            selectedState.speed = 1
            try expectEqual(selectedState.speedDisplayText, "快速")
            selectedState.speed = 2
            try expectEqual(selectedState.speedDisplayText, "快速+")
            selectedState.speed = 3
            try expectEqual(selectedState.speedDisplayText, "快速++")
            selectedState.speed = 4
            try expectEqual(selectedState.speedDisplayText, "快速+++")
            selectedState.speed = 5
            try expectEqual(selectedState.speedDisplayText, "快速++++")
        },
        TestCase("PaperlikeDeviceControllerTests.timesOutAndCloses") {
            let serial = FakeSerialConnection(shouldRespond: false)
            let controller = PaperlikeDeviceController(
                requestTimeout: .milliseconds(20),
                connectionFactory: { _ in serial }
            )

            do {
                try await controller.connect(path: serial.path)
                throw TestFailure(description: "connect unexpectedly succeeded")
            } catch let error as PaperlikeDeviceError {
                try expectEqual(error, .timedOut)
            }
            let closed = await serial.isClosed()
            try expect(closed, "serial port must close after timeout")
        },
        TestCase("PaperlikeDeviceControllerTests.publishesIdleDisconnect") {
            let serial = FakeSerialConnection()
            let controller = PaperlikeDeviceController(
                connectionFactory: { _ in serial }
            )
            var events = controller.events.makeAsyncIterator()
            _ = await events.next()

            try await controller.connect(path: serial.path)
            _ = await events.next()
            _ = await events.next()

            await serial.finishIncoming()
            try expectEqual(
                await events.next(),
                .failed(message: "与显示器的连接已中断。")
            )
            let closed = await serial.isClosed()
            try expect(closed, "serial must close after EOF")
        },
        TestCase("PaperlikeDeviceControllerTests.rejectsUnsupportedMCU") {
            let serial = FakeSerialConnection(mcuValue: 0x22)
            let controller = PaperlikeDeviceController(
                connectionFactory: { _ in serial }
            )

            do {
                try await controller.connect(path: serial.path)
                throw TestFailure(description: "unsupported MCU was accepted")
            } catch let error as PaperlikeDeviceError {
                try expectEqual(
                    error,
                    .unsupported(identifier: "MCU 22 / 型号 01")
                )
            }
            try expectEqual(
                await controller.currentState(),
                .unsupported(identifier: "MCU 22 / 型号 01")
            )
        },
        TestCase("HardwareFixture.loadsCapturedSession") {
            let fixtureURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("paperlike-13k-color-session.json")
            let data = try Data(contentsOf: fixtureURL)
            let object = try JSONSerialization.jsonObject(with: data)
            guard let fixture = object as? [String: Any],
                  let device = fixture["device"] as? [String: String],
                  let actions = fixture["verifiedActions"] as? [[String: Any]]
            else {
                throw TestFailure(description: "invalid hardware fixture")
            }
            try expectEqual(device["mcu"], "30")
            try expectEqual(device["family"], "01")
            try expectEqual(
                device["captureStatus"],
                "早期原型受控采集，仅保留历史证据"
            )
            try expect(actions.count >= 10, "fixture must cover every action")
        },
        TestCase("OfficialCommandMap.usesFiveLevelSpeedCommand") {
            let fixtureURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures")
                .appendingPathComponent(
                    "paperlike-v2.0.3-command-map.json"
                )
            let data = try Data(contentsOf: fixtureURL)
            let object = try JSONSerialization.jsonObject(with: data)
            guard let fixture = object as? [String: Any],
                  let speed = fixture["speed"] as? [String: Any],
                  let prefixes = speed["requestPrefixes"] as? [String],
                  let values = speed["values"] as? [Int]
            else {
                throw TestFailure(description: "invalid command map")
            }
            try expectEqual(speed["command"] as? String, "04")
            try expectEqual(values, [1, 2, 3, 4, 5])
            try expectEqual(
                prefixes,
                ["0401", "0402", "0403", "0404", "0405"]
            )
            try expect(
                prefixes.allSatisfy { !$0.hasPrefix("13") },
                "current speed map must not use command 13"
            )
        }
    ]
}
