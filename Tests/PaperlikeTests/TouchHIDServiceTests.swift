import CoreGraphics
import Foundation
@testable import PaperlikeTouch

func touchHIDServiceTests() -> [TestCase] {
    [
        TestCase("TouchHIDService.registersManagerInputReportCallbackBeforeActivation") {
            let source = try touchHIDSource()
            let registration = source.range(
                of: "IOHIDManagerRegisterInputReportWithTimeStampCallback"
            )
            let activation = source.range(of: "IOHIDManagerActivate")

            try expect(registration != nil, "manager-level input report callback is registered")
            try expect(activation != nil, "HID manager is activated")
            if let registration, let activation {
                try expect(
                    registration.upperBound < activation.lowerBound,
                    "input report callback is registered before activation"
                )
            }
            try expect(
                !source.contains("IOHIDDeviceRegisterInputReport"),
                "no device-level input report callback is registered after activation"
            )
        },
        TestCase("HIDDeviceRegistry.retainsIdentityUntilSessionCancellation") {
            weak var retainedFirstDevice: RegistryFixtureDevice?
            var registry: HIDDeviceRegistry<RegistryFixtureDevice>? = HIDDeviceRegistry()

            do {
                let firstDevice = RegistryFixtureDevice()
                retainedFirstDevice = firstDevice
                let firstMatch = registry!.connect(firstDevice)
                let repeatedMatch = registry!.connect(firstDevice)

                try expectEqual(firstMatch, true)
                try expectEqual(repeatedMatch, false)
                try expectEqual(registry!.disconnect(firstDevice), true)
            }

            try expect(retainedFirstDevice != nil, "disconnected device remains retained until cancellation")

            let secondDevice = RegistryFixtureDevice()
            let secondMatch = registry!.connect(secondDevice)
            try expectEqual(secondMatch, true)

            registry = nil
            try expect(retainedFirstDevice == nil, "device releases with cancelled session registry")
        },
        TestCase("OrderedTouchInputEventHandoff.awaitsEachDeliveryInFIFOOrder") {
            let recorder = await MainActor.run { HandoffRecorder() }
            let handoff = OrderedTouchInputEventHandoff { event in
                if case .connected = event {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                recorder.record(event)
            }

            handoff.submit(.connected)
            handoff.submit(.report([1], timestamp: 1))
            handoff.submit(.failure("failed"))
            handoff.submit(.disconnected)
            handoff.finish()
            try await waitForRecordedEvents(recorder, count: 4)

            let labels = await MainActor.run { recorder.labels }
            try expectEqual(labels, ["connected", "report", "failure", "disconnected"])
        },
        TestCase("TouchMappingService.processesAsynchronousFakeInputInFIFOOrder") {
            try await asynchronousFakeInputIntegrationTest()
        }
    ]
}

private final class RegistryFixtureDevice {}

@MainActor
private final class HandoffRecorder {
    private(set) var labels: [String] = []

    func record(_ event: TouchInputEvent) {
        switch event {
        case .connected:
            labels.append("connected")
        case .disconnected:
            labels.append("disconnected")
        case .report:
            labels.append("report")
        case .failure:
            labels.append("failure")
        }
    }
}

private func waitForRecordedEvents(
    _ recorder: HandoffRecorder,
    count: Int
) async throws {
    for _ in 0..<200 {
        if await MainActor.run(body: { recorder.labels.count >= count }) {
            return
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw TestFailure(description: "timed out waiting for \(count) ordered HID events")
}

private func asynchronousFakeInputIntegrationTest() async throws {
    let harness = await MainActor.run { AsyncIntegrationHarness() }

    await MainActor.run {
        harness.input.emit([
            .connected,
            .report(hidFixtureReport(x: 1_024), timestamp: 1),
            .report(hidFixtureReport(x: 2_048), timestamp: 1.1),
            .disconnected
        ])
    }

    for _ in 0..<200 {
        let eventCount = await MainActor.run { harness.poster.events.count }
        if eventCount >= 4 {
            break
        }
        try await Task.sleep(for: .milliseconds(2))
    }

    try await MainActor.run {
        try expectEqual(harness.poster.events, [
            .move(CGPoint(x: 480, y: 540)),
            .leftDown(CGPoint(x: 960, y: 540)),
            .leftDragged(CGPoint(x: 960, y: 540)),
            .leftUp(CGPoint(x: 960, y: 540))
        ])
        try expectEqual(harness.service.status, .deviceUnavailable)
        harness.service.shutdown()
    }
}

@MainActor
private final class AsyncIntegrationHarness {
    let service: TouchMappingService
    let input: AsynchronousFakeTouchInputSource
    let poster: AsyncFakeTouchEventPoster

    private let defaults: UserDefaults
    private let suiteName: String

    init() {
        suiteName = "PaperlikeTests.AsyncTouchInput.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        input = AsynchronousFakeTouchInputSource()
        poster = AsyncFakeTouchEventPoster()
        let store = TouchSettingsStore(defaults: defaults)
        store.save(TouchMappingSettings(isEnabled: true, isSingleFingerScrollEnabled: false))
        service = TouchMappingService(
            inputSource: input,
            eventPoster: poster,
            displayProvider: AsyncFakeTouchDisplayProvider(),
            accessibility: AsyncFakeAccessibilityChecker(),
            settingsStore: store
        )
        service.start()
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private func hidFixtureReport(x: UInt16) -> [UInt8] {
    var report = Array(repeating: UInt8(0), count: 84)
    report[0] = 1
    report[1] = 1
    report[2] = 7
    report[3] = UInt8(truncatingIfNeeded: x)
    report[4] = UInt8(truncatingIfNeeded: x >> 8)
    report[5] = 0
    report[6] = 8
    report[7] = 20
    report[83] = 1
    return report
}

@MainActor
private final class AsynchronousFakeTouchInputSource: TouchInputSource {
    private(set) var isConnected = false
    var eventHandler: ((TouchInputEvent) -> Void)?
    private var handoff: OrderedTouchInputEventHandoff?

    func start() {
        handoff = OrderedTouchInputEventHandoff { [weak self] event in
            guard let self else {
                return
            }
            switch event {
            case .connected:
                isConnected = true
            case .disconnected:
                isConnected = false
            case .report, .failure:
                break
            }
            eventHandler?(event)
        }
    }

    func stop() {
        handoff?.finish()
        handoff = nil
        isConnected = false
    }

    func emit(_ events: [TouchInputEvent]) {
        events.forEach { handoff?.submit($0) }
    }
}

@MainActor
private final class AsyncFakeTouchEventPoster: TouchEventPosting {
    private(set) var events: [TouchOutputEvent] = []

    func post(_ event: TouchOutputEvent) {
        events.append(event)
    }
}

@MainActor
private final class AsyncFakeTouchDisplayProvider: TouchDisplayProviding {
    var displaysDidChange: (() -> Void)?

    func displays() -> [TouchDisplay] {
        [TouchDisplay(
            id: 11,
            name: "Paperlike13K Color",
            bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        )]
    }

    func startObserving() {}
    func stopObserving() {}
}

@MainActor
private final class AsyncFakeAccessibilityChecker: AccessibilityChecking {
    func checkIsTrusted() -> Bool { true }
    func requestTrustPrompt() -> Bool { true }
}

private func touchHIDSource() throws -> String {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let file = root
        .appendingPathComponent("Sources/PaperlikeTouch/TouchHIDService.swift")
    return try String(contentsOf: file, encoding: .utf8)
}
