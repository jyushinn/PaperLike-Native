import Darwin
import Foundation
import IOKit.hid

public enum TouchInputEvent: Sendable {
    case connected
    case disconnected
    case report([UInt8], timestamp: TimeInterval)
    case failure(String)
}

@MainActor
public protocol TouchInputSource: AnyObject {
    var isConnected: Bool { get }
    var coordinateBounds: TouchCalibration? { get }
    var eventHandler: ((TouchInputEvent) -> Void)? { get set }
    func start()
    func stop()
}

public extension TouchInputSource {
    var coordinateBounds: TouchCalibration? { nil }
}

@MainActor
public final class TouchHIDService: TouchInputSource {
    public private(set) var isConnected = false
    public var coordinateBounds: TouchCalibration? { resources?.coordinateBounds }
    public var eventHandler: ((TouchInputEvent) -> Void)?

    private var resources: HIDResources?
    private var handoff: OrderedTouchInputEventHandoff?
    private var generation: UInt64 = 0

    public init() {}

    public func start() {
        guard resources == nil else {
            return
        }

        do {
            generation &+= 1
            let generation = generation
            let handoff = OrderedTouchInputEventHandoff { [weak self] event in
                guard let self,
                      self.generation == generation,
                      self.resources != nil else {
                    return
                }
                self.receive(event)
            }
            self.handoff = handoff
            let resources = try HIDResources { event in
                handoff.submit(event)
            }
            self.resources = resources
            try resources.start()
        } catch {
            resources?.cancel()
            resources = nil
            handoff?.cancel()
            handoff = nil
            receive(.failure(String(describing: error)))
        }
    }

    public func stop() {
        generation &+= 1
        let resources = self.resources
        self.resources = nil
        resources?.cancel()
        handoff?.cancel()
        handoff = nil
        if isConnected {
            receive(.disconnected)
        }
    }

    isolated deinit {
        resources?.cancel()
        handoff?.cancel()
    }

    private func receive(_ event: TouchInputEvent) {
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

final class OrderedTouchInputEventHandoff: Sendable {
    private let continuation: AsyncStream<TouchInputEvent>.Continuation
    private let consumer: Task<Void, Never>

    init(
        deliver: @escaping @MainActor @Sendable (TouchInputEvent) async -> Void
    ) {
        let channel = AsyncStream.makeStream(
            of: TouchInputEvent.self,
            bufferingPolicy: .unbounded
        )
        continuation = channel.continuation
        consumer = Task {
            for await event in channel.stream {
                guard !Task.isCancelled else {
                    return
                }
                await deliver(event)
            }
        }
    }

    func submit(_ event: TouchInputEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }

    func cancel() {
        continuation.finish()
        consumer.cancel()
    }

    deinit {
        continuation.finish()
        consumer.cancel()
    }
}

private enum HIDServiceError: Error, CustomStringConvertible {
    case managerOpenFailed(IOReturn)

    var description: String {
        switch self {
        case let .managerOpenFailed(result):
            return "Unable to open IOHIDManager (\(result))"
        }
    }
}

private final class HIDResources: @unchecked Sendable {
    private let manager: IOHIDManager
    private let queue = DispatchQueue(label: "PaperLikeNative.TouchHID")
    private let callbackContext: HIDCallbackContext
    private let cancellationLifetime: HIDCancellationLifetime
    private var activated = false
    var coordinateBounds: TouchCalibration? { callbackContext.coordinateBounds }

    init(handler: @escaping @Sendable (TouchInputEvent) -> Void) throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        callbackContext = HIDCallbackContext(handler: handler)
        cancellationLifetime = HIDCancellationLifetime()
        cancellationLifetime.resources = self
    }

    func start() throws {
        let descriptor = TouchDeviceDescriptor.paperLike13KColor
        let matching = [
            kIOHIDVendorIDKey as String: Int(descriptor.vendorID),
            kIOHIDProductIDKey as String: Int(descriptor.productID),
            kIOHIDPrimaryUsagePageKey as String: Int(descriptor.usagePage),
            kIOHIDPrimaryUsageKey as String: Int(descriptor.usage)
        ] as CFDictionary
        let context = Unmanaged.passUnretained(callbackContext).toOpaque()

        IOHIDManagerSetDeviceMatching(manager, matching)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemoved, context)
        IOHIDManagerRegisterInputReportWithTimeStampCallback(
            manager,
            hidInputReportReceived,
            context
        )
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerSetCancelHandler(manager) { [cancellationLifetime] in
            cancellationLifetime.finishCancellation()
        }

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw HIDServiceError.managerOpenFailed(openResult)
        }

        activated = true
        IOHIDManagerActivate(manager)
    }

    func cancel() {
        callbackContext.deactivate()
        if activated {
            activated = false
            IOHIDManagerCancel(manager)
        } else {
            cancellationLifetime.finishCancellation()
        }
    }

    func closeAfterCancellation() {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

private final class HIDCancellationLifetime: @unchecked Sendable {
    private let lock = NSLock()
    var resources: HIDResources?

    func finishCancellation() {
        lock.lock()
        let retainedResources = resources
        resources = nil
        lock.unlock()
        retainedResources?.closeAfterCancellation()
    }
}

private final class HIDCallbackContext: @unchecked Sendable {
    private static let reportByteCount = 84

    private let handler: @Sendable (TouchInputEvent) -> Void
    private let stateLock = NSLock()
    private var active = true
    private var currentBounds: TouchCalibration?
    private let deviceRegistry = HIDDeviceRegistry<IOHIDDevice>()

    var coordinateBounds: TouchCalibration? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentBounds
    }

    init(handler: @escaping @Sendable (TouchInputEvent) -> Void) {
        self.handler = handler
    }

    func deactivate() {
        stateLock.lock()
        active = false
        stateLock.unlock()
    }

    func matched(device: IOHIDDevice, result: IOReturn) {
        guard result == kIOReturnSuccess else {
            deliver(.failure("HID match failed (\(result))"))
            return
        }

        if deviceRegistry.connect(device) {
            stateLock.lock()
            currentBounds = Self.logicalBounds(for: device)
            stateLock.unlock()
            deliver(.connected)
        }
    }

    func removed(device: IOHIDDevice, result: IOReturn) {
        guard result == kIOReturnSuccess else {
            deliver(.failure("HID removal failed (\(result))"))
            return
        }
        if deviceRegistry.disconnect(device) {
            stateLock.lock()
            currentBounds = nil
            stateLock.unlock()
            deliver(.disconnected)
        }
    }

    func received(
        result: IOReturn,
        type: IOHIDReportType,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex,
        timestamp: UInt64
    ) {
        guard result == kIOReturnSuccess else {
            deliver(.failure("HID input report failed (\(result))"))
            return
        }
        guard type == kIOHIDReportTypeInput else {
            return
        }
        guard reportLength == Self.reportByteCount else {
            deliver(.report([], timestamp: hidTimeInterval(timestamp)))
            return
        }
        let bytes = Array(UnsafeBufferPointer(start: report, count: Self.reportByteCount))
        deliver(.report(bytes, timestamp: hidTimeInterval(timestamp)))
    }

    private func deliver(_ event: TouchInputEvent) {
        stateLock.lock()
        let shouldDeliver = active
        stateLock.unlock()
        if shouldDeliver {
            handler(event)
        }
    }

    private static func logicalBounds(for device: IOHIDDevice) -> TouchCalibration? {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] else {
            return nil
        }
        func uniqueRange(for usage: Int) -> (Int, Int)? {
            let ranges = elements
                .filter { Int(IOHIDElementGetUsagePage($0)) == 1 && Int(IOHIDElementGetUsage($0)) == usage }
                .map { (IOHIDElementGetLogicalMin($0), IOHIDElementGetLogicalMax($0)) }
            guard let first = ranges.first, ranges.allSatisfy({ $0 == first }) else { return nil }
            return first
        }
        guard let x = uniqueRange(for: 0x30), let y = uniqueRange(for: 0x31) else { return nil }
        return TouchCalibration.hidLogicalBounds(minX: x.0, maxX: x.1, minY: y.0, maxY: y.1)
    }
}

final class HIDDeviceRegistry<Device: AnyObject> {
    private struct Entry {
        let device: Device
        var isConnected: Bool
    }

    private var entries: [Entry] = []

    func connect(_ device: Device) -> Bool {
        let hadConnectedDevice = entries.contains(where: \.isConnected)
        if let index = entries.firstIndex(where: { $0.device === device }) {
            let wasConnected = entries[index].isConnected
            entries[index].isConnected = true
            return !hadConnectedDevice && !wasConnected
        }

        entries.append(Entry(device: device, isConnected: true))
        return !hadConnectedDevice
    }

    func disconnect(_ device: Device) -> Bool {
        guard let index = entries.firstIndex(where: { $0.device === device }),
              entries[index].isConnected else {
            return false
        }
        entries[index].isConnected = false
        return !entries.contains(where: \.isConnected)
    }
}

private func hidDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else {
        return
    }
    Unmanaged<HIDCallbackContext>.fromOpaque(context).takeUnretainedValue()
        .matched(device: device, result: result)
}

private func hidDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else {
        return
    }
    Unmanaged<HIDCallbackContext>.fromOpaque(context).takeUnretainedValue()
        .removed(device: device, result: result)
}

private func hidInputReportReceived(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex,
    timestamp: UInt64
) {
    guard let context else {
        return
    }
    Unmanaged<HIDCallbackContext>.fromOpaque(context).takeUnretainedValue().received(
        result: result,
        type: type,
        report: report,
        reportLength: reportLength,
        timestamp: timestamp
    )
}

private func hidTimeInterval(_ timestamp: UInt64) -> TimeInterval {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let nanoseconds = Double(timestamp) * Double(info.numer) / Double(info.denom)
    return nanoseconds / 1_000_000_000
}
