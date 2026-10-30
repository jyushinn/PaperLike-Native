import Foundation
import SerialTransport

func serialDeviceMonitorTests() -> [TestCase] {
    [
        TestCase("SerialDeviceMonitorTests.emitsSortedChangesOnly") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            let monitor = SerialDeviceMonitor(
                directory: directory,
                pollingInterval: .milliseconds(10)
            )
            var iterator = monitor.devices.makeAsyncIterator()

            try expectEqual(await iterator.next(), [])

            let ignored = directory.appendingPathComponent("tty.bluetooth")
            let second = directory.appendingPathComponent("cu.usbserial-200")
            let first = directory.appendingPathComponent("cu.usbserial-100")
            FileManager.default.createFile(atPath: ignored.path, contents: Data())
            FileManager.default.createFile(atPath: second.path, contents: Data())
            FileManager.default.createFile(atPath: first.path, contents: Data())

            try expectEqual(
                await iterator.next(),
                [first.path, second.path]
            )
        },
        TestCase("SerialDeviceMonitorTests.stopFinishesPollingAndNotifications") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            for path in [directory, URL(fileURLWithPath: "/dev", isDirectory: true)] {
                let monitor = SerialDeviceMonitor(directory: path, pollingInterval: .milliseconds(10))
                var iterator = monitor.devices.makeAsyncIterator()
                _ = await iterator.next()
                monitor.stop()
                monitor.stop()
                try expectEqual(await iterator.next(), nil)
            }
        }
    ]
}
