import Foundation
import IOKit
import IOKit.serial

public final class SerialDeviceMonitor: @unchecked Sendable {
    public let devices: AsyncStream<[String]>

    private var notifyPort: IONotificationPortRef?
    private var queue: DispatchQueue?
    private var publishIterator: io_iterator_t = 0
    private var terminateIterator: io_iterator_t = 0
    private var pollingTask: Task<Void, Never>?
    private let stopLock = NSLock()
    private let queueKey = DispatchSpecificKey<Bool>()
    private var continuationBox: ContinuationBox?
    private var continuation: AsyncStream<[String]>.Continuation?

    public init(
        directory: URL = URL(fileURLWithPath: "/dev", isDirectory: true),
        pollingInterval: Duration = .seconds(1)
    ) {
        let pair = AsyncStream<[String]>.makeStream()
        self.devices = pair.stream
        self.continuation = pair.continuation

        // 生产环境 (/dev) 采用零能耗的 IOKit 事件监听机制
        if directory.path == "/dev" {
            let queue = DispatchQueue(label: "com.paperlike.native.serial.monitor")
            self.queue = queue
            queue.setSpecific(key: queueKey, value: true)

            guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
                self.startPolling(directory: directory, interval: pollingInterval, continuation: pair.continuation)
                return
            }
            self.notifyPort = port
            IONotificationPortSetDispatchQueue(port, queue)

            let box = ContinuationBox(continuation: pair.continuation, directory: directory)
            self.continuationBox = box
            let refCon = Unmanaged.passUnretained(box).toOpaque()

            let matchingPublish = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
            matchingPublish[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

            var pubIterator: io_iterator_t = 0
            let pubResult = IOServiceAddMatchingNotification(
                port,
                kIOPublishNotification,
                matchingPublish,
                { refCon, iterator in
                    while case let entry = IOIteratorNext(iterator), entry != 0 {
                        IOObjectRelease(entry)
                    }
                    guard let refCon else { return }
                    let box = Unmanaged<ContinuationBox>.fromOpaque(refCon).takeUnretainedValue()
                    box.emitCurrentPaths()
                },
                refCon,
                &pubIterator
            )

            if pubResult == KERN_SUCCESS {
                self.publishIterator = pubIterator
                while case let entry = IOIteratorNext(pubIterator), entry != 0 {
                    IOObjectRelease(entry)
                }
            }

            let matchingTerminate = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
            matchingTerminate[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

            var termIterator: io_iterator_t = 0
            let termResult = IOServiceAddMatchingNotification(
                port,
                kIOTerminatedNotification,
                matchingTerminate,
                { refCon, iterator in
                    while case let entry = IOIteratorNext(iterator), entry != 0 {
                        IOObjectRelease(entry)
                    }
                    guard let refCon else { return }
                    let box = Unmanaged<ContinuationBox>.fromOpaque(refCon).takeUnretainedValue()
                    box.emitCurrentPaths()
                },
                refCon,
                &termIterator
            )

            if termResult == KERN_SUCCESS {
                self.terminateIterator = termIterator
                while case let entry = IOIteratorNext(termIterator), entry != 0 {
                    IOObjectRelease(entry)
                }
            }

            queue.sync { box.emitCurrentPaths() }
        } else {
            // 测试或调试自定义路径时，回退到轮询以保持测试兼容性
            self.startPolling(directory: directory, interval: pollingInterval, continuation: pair.continuation)
        }
    }

    deinit {
        stop()
    }

    public func stop() {
        stopLock.lock()
        pollingTask?.cancel()
        pollingTask = nil
        // Cancel delivery before draining the callback queue and releasing its context.
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
        let releaseCallbacks = {
            if self.publishIterator != 0 { IOObjectRelease(self.publishIterator) }
            if self.terminateIterator != 0 { IOObjectRelease(self.terminateIterator) }
            self.publishIterator = 0
            self.terminateIterator = 0
            self.continuationBox = nil
        }
        if let queue, DispatchQueue.getSpecific(key: queueKey) != true {
            queue.sync(execute: releaseCallbacks)
        } else {
            releaseCallbacks()
        }
        let continuation = self.continuation
        self.continuation = nil
        stopLock.unlock()
        continuation?.finish()
    }

    private func startPolling(
        directory: URL,
        interval: Duration,
        continuation: AsyncStream<[String]>.Continuation
    ) {
        pollingTask = Task.detached {
            var lastPaths: [String]?
            while !Task.isCancelled {
                let paths = ContinuationBox.serialPaths(in: directory)
                if paths != lastPaths {
                    continuation.yield(paths)
                    lastPaths = paths
                }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
            }
            continuation.finish()
        }
    }

    private final class ContinuationBox {
        let continuation: AsyncStream<[String]>.Continuation
        let directory: URL
        private var lastPaths: [String]?

        init(continuation: AsyncStream<[String]>.Continuation, directory: URL) {
            self.continuation = continuation
            self.directory = directory
        }

        func emitCurrentPaths() {
            let paths = Self.serialPaths(in: directory)
            if paths != lastPaths {
                continuation.yield(paths)
                lastPaths = paths
            }
        }

        static func serialPaths(in directory: URL) -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: directory.path
            )) ?? []

            return names
                .filter { $0.hasPrefix("cu.usbserial-") }
                .map { directory.appendingPathComponent($0).path }
                .sorted()
        }
    }
}
