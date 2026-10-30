import Foundation
import PaperlikeCore
import CoreGraphics

func displayDriverServiceTests() -> [TestCase] {
    [
        TestCase("DisplayDriverService.booleanRestoreRejectsReplacementAndKeepsBackup") {
            let backend = FakeDisplayDriverBackend(values: ["enableDither": true])
            let service = DisplayDriverService(backend: backend)
            try service.setDitheringEnabled(false)
            backend.connected = [DisplayDriverDisplay(id: 1, stableID: "replacement", name: "Paperlike")]
            do { try service.restoreDithering(); throw TestFailure(description: "must not restore original value to replacement display") }
            catch DisplayDriverError.displayUnavailable { }
            try expectEqual(try backend.boolean("enableDither"), false)
            backend.connected = [DisplayDriverDisplay(id: 7, stableID: "original", name: "Paperlike")]
            try service.restoreDithering()
            try expectEqual(try backend.boolean("enableDither"), true)
        },
        TestCase("DisplayDriverService.booleanWriteRejectsAmbiguousDisplays") {
            let backend = FakeDisplayDriverBackend(values: ["enableDither": true])
            let service = DisplayDriverService(backend: backend)
            backend.connected.append(DisplayDriverDisplay(id: 2, stableID: "second", name: "Paperlike"))
            do { try service.setDitheringEnabled(false); throw TestFailure(description: "ambiguous write accepted") }
            catch DisplayDriverError.ambiguousPaperlikeDisplays { }
            try expectEqual(try backend.boolean("enableDither"), true)
        },
        TestCase("DisplayDriverServiceTests.rejectedUnchangedBooleanDoesNotLeaveRestoreFailure") {
            let backend = FakeDisplayDriverBackend(values: ["uniformity2D": false])
            let service = DisplayDriverService(backend: backend)
            backend.failBooleanWrite = true
            try expectThrows(FakeGammaError.write) { try service.setEnhancementEnabled(true) }
            try service.restore()
            try expectEqual(try service.enhancementEnabled(), false)
            backend.connected = []
            try service.restore() // Successfully verified original value cleared the pending backup.
        },
        TestCase("DisplayDriverServiceTests.failedBooleanRestoreKeepsChangedValueForRetry") {
            let backend = FakeDisplayDriverBackend(values: ["enableDither": false])
            let service = DisplayDriverService(backend: backend)
            try service.setDitheringEnabled(true)
            backend.failBooleanWrite = true
            try expectThrows(FakeGammaError.write) { try service.restore() }
            try expectEqual(try service.ditheringEnabled(), true)
            backend.failBooleanWrite = false
            try service.restore()
            try expectEqual(try service.ditheringEnabled(), false)
        },
        TestCase("DisplayDriverServiceTests.failedBooleanRestoreWithUnreadableValueKeepsBackup") {
            let backend = FakeDisplayDriverBackend(values: ["enableDither": false])
            let service = DisplayDriverService(backend: backend)
            try service.setDitheringEnabled(true)
            backend.failBooleanWrite = true
            backend.failBooleanRead = true
            try expectThrows(FakeGammaError.write) { try service.restore() }
            backend.failBooleanRead = false
            backend.failBooleanWrite = false
            try service.restore()
            try expectEqual(try service.ditheringEnabled(), false)
        },
        TestCase("DisplayDriverServiceTests.readsRealDitheringValue") {
            let backend = FakeDisplayDriverBackend(
                values: ["enableDither": true]
            )
            let service = DisplayDriverService(backend: backend)

            try expectEqual(try service.ditheringEnabled(), true)
        },
        TestCase("DisplayDriverServiceTests.restoresOriginalDithering") {
            let backend = FakeDisplayDriverBackend(
                values: ["enableDither": true]
            )
            let service = DisplayDriverService(backend: backend)

            try service.setDitheringEnabled(false)
            try expectEqual(try backend.boolean("enableDither"), false)

            try service.restoreDithering()

            try expectEqual(try backend.boolean("enableDither"), true)
        },
        TestCase("DisplayDriverServiceTests.gammaPreservesEndpointsAndLowEndDetail") {
            let backend = FakeDisplayDriverBackend(values: [:])
            let service = DisplayDriverService(backend: backend)
            try calibrate(service, saturation: 0)
            let table = backend.table(for: 1)
            try expectEqual(table.red.count, 5)
            try expectEqual(table.red.first, 0)
            try expectEqual(table.red.last, 1)
            try expect(zip(table.red, table.red.dropFirst()).allSatisfy { $0 < $1 }, "low contrast must retain monotonic detail")
            try expect(table.red[1] > 0.25 && table.red[1] < 0.5, "low contrast must soften without flattening")
            try calibrate(service, saturation: 1)
            let high = backend.table(for: 1).red
            try expectEqual(high.first, 0)
            try expectEqual(high.last, 1)
            try expect(zip(high, high.dropFirst()).allSatisfy { $0 < $1 }, "high contrast must remain monotonic")
        },
        TestCase("DisplayDriverServiceTests.neutralRestoresExactOriginalSamples") {
            let backend = FakeDisplayDriverBackend(values: [:])
            let original = backend.table(for: 1)
            let service = DisplayDriverService(backend: backend)
            try calibrate(service, saturation: 0)
            try calibrate(service, saturation: 0.5)
            try expectEqual(backend.table(for: 1), original)
            try expectEqual(backend.readCount, 1)
            try service.restore()
            try expectEqual(backend.writes.count, 2)
        },
        TestCase("DisplayDriverServiceTests.advancedGammaIsNormalizedPerChannel") {
            let backend = FakeDisplayDriverBackend(values: [:])
            let service = DisplayDriverService(backend: backend)
            try service.applyDisplayCalibration(saturation: 0.5, redThreshold: 0.2, greenThreshold: 0.5, blueThreshold: 0.8, contrastSlope: 8, isGrayscaleEnabled: true)
            let table = backend.table(for: 1)
            for channel in [table.red, table.green, table.blue] {
                try expectEqual(channel.first, 0)
                try expectEqual(channel.last, 1)
                try expect(zip(channel, channel.dropFirst()).allSatisfy { $0 < $1 }, "advanced channel must be monotonic")
            }
            try expect(table.red != table.blue, "channel curves are not a grayscale conversion")
        },
        TestCase("DisplayDriverServiceTests.restoresOnlyStableIdentityAfterReconnect") {
            let backend = FakeDisplayDriverBackend(values: [:])
            let original = backend.table(for: 1)
            let service = DisplayDriverService(backend: backend)
            try calibrate(service, saturation: 0)
            backend.connected = [DisplayDriverDisplay(id: 1, stableID: "other", name: "Paperlike")]
            do { try service.restore(); throw TestFailure(description: "missing original display must throw") }
            catch DisplayDriverError.displayUnavailable { }
            try expectEqual(backend.writes.count, 1)
            backend.connected = [DisplayDriverDisplay(id: 7, stableID: "original", name: "Paperlike")]
            try service.restore()
            try expectEqual(backend.writes.last?.0, 7)
            try expectEqual(backend.table(for: 7), original)
        },
        TestCase("DisplayDriverServiceTests.readFailureNeverWrites") {
            let backend = FakeDisplayDriverBackend(values: [:])
            backend.failRead = true
            let service = DisplayDriverService(backend: backend)
            try expectThrows(FakeGammaError.read) { try calibrate(service, saturation: 0) }
            try expectEqual(backend.writes.count, 0)
            try service.restore()
            try expectEqual(backend.writes.count, 0)
        },
        TestCase("DisplayDriverServiceTests.writeFailuresKeepBackupForRetry") {
            let backend = FakeDisplayDriverBackend(values: [:])
            let original = backend.table(for: 1)
            let service = DisplayDriverService(backend: backend)
            backend.failWrite = true
            try expectThrows(FakeGammaError.write) { try calibrate(service, saturation: 0) }
            try expectThrows(FakeGammaError.write) { try service.restore() }
            backend.failWrite = false
            try service.restore()
            try expectEqual(backend.table(for: 1), original)
            try expectEqual(backend.readCount, 1)
            try expectEqual(backend.writes.count, 1)
        },
        TestCase("DisplayDriverServiceTests.rejectsAmbiguousTargetsAndAcceptsExplicitTarget") {
            let backend = FakeDisplayDriverBackend(values: [:])
            backend.connected.append(DisplayDriverDisplay(id: 2, stableID: "second", name: "Paperlike"))
            let service = DisplayDriverService(backend: backend)
            do { try calibrate(service, saturation: 0); throw TestFailure(description: "ambiguous display must throw") }
            catch DisplayDriverError.ambiguousPaperlikeDisplays { }
            try expectEqual(backend.writes.count, 0)
            try service.applyDisplayCalibration(saturation: 0, redThreshold: 0.5, greenThreshold: 0.5, blueThreshold: 0.5, contrastSlope: 8, isGrayscaleEnabled: false, targetDisplayID: 2)
            try expectEqual(backend.writes.last?.0, 2)
        },
        TestCase("DisplayDriverServiceTests.gammaOnlyRestoreLeavesBooleanChangesApplied") {
            let backend = FakeDisplayDriverBackend(values: ["enableDither": true])
            let service = DisplayDriverService(backend: backend)
            try service.setDitheringEnabled(false)
            try calibrate(service, saturation: 0)
            try service.restoreDisplayCalibration()
            try expectEqual(backend.table(for: 1).red, [0, 0.2, 0.45, 0.8, 1])
            try expectEqual(try backend.boolean("enableDither"), false)
            try service.restore()
            try expectEqual(try backend.boolean("enableDither"), true)
        },
        TestCase("DisplayDriverServiceTests.neutralWithoutBackupDoesNotTouchDisplay") {
            let backend = FakeDisplayDriverBackend(values: [:])
            backend.connected = []
            let service = DisplayDriverService(backend: backend)
            try calibrate(service, saturation: 0.5)
            try expectEqual(backend.readCount, 0)
            do { try calibrate(service, saturation: 0); throw TestFailure(description: "missing display must throw") }
            catch DisplayDriverError.paperlikeDisplayNotFound { }
        }
    ]
}

private func calibrate(_ service: DisplayDriverService, saturation: Double) throws {
    try service.applyDisplayCalibration(saturation: saturation, redThreshold: 0.5, greenThreshold: 0.5, blueThreshold: 0.5, contrastSlope: 8, isGrayscaleEnabled: false)
}

private enum FakeGammaError: Error, Equatable { case read, write }

private final class FakeDisplayDriverBackend:
    DisplayDriverBackend,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: Bool]
    var connected = [DisplayDriverDisplay(id: 1, stableID: "original", name: "Paperlike")]
    var failBooleanWrite = false
    var failBooleanRead = false
    var failRead = false
    var failWrite = false
    var readCount = 0
    var writes: [(CGDirectDisplayID, DisplayGammaTable)] = []
    private var gamma = [CGDirectDisplayID: DisplayGammaTable]()

    init(values: [String: Bool]) {
        self.values = values
    }

    func readBoolean(_ property: String, for display: DisplayDriverDisplay) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if failBooleanRead { throw FakeGammaError.read }
        guard let value = values[property] else {
            throw DisplayDriverError.propertyUnavailable(property)
        }
        return value
    }

    func writeBoolean(_ value: Bool, property: String, for display: DisplayDriverDisplay) throws {
        lock.lock()
        defer { lock.unlock() }
        if failBooleanWrite { throw FakeGammaError.write }
        values[property] = value
    }

    func boolean(_ property: String) throws -> Bool {
        try readBoolean(property, for: connected[0])
    }

    func displays() throws -> [DisplayDriverDisplay] { connected }

    func gammaTable(for displayID: CGDirectDisplayID) throws -> DisplayGammaTable {
        if failRead { throw FakeGammaError.read }
        readCount += 1
        return table(for: displayID)
    }

    func table(for displayID: CGDirectDisplayID) -> DisplayGammaTable {
        return gamma[displayID] ?? DisplayGammaTable(red: [0, 0.2, 0.45, 0.8, 1], green: [0, 0.1, 0.4, 0.7, 1], blue: [0, 0.3, 0.6, 0.9, 1])
    }

    func setGammaTable(_ table: DisplayGammaTable, for displayID: CGDirectDisplayID) throws {
        if failWrite { throw FakeGammaError.write }
        writes.append((displayID, table))
        gamma[displayID] = table
    }
}
