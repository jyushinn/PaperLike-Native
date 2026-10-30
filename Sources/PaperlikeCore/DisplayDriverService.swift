import Foundation
import IOKit
import CoreGraphics
import ColorSync

public enum DisplayDriverError: Error, LocalizedError {
    case paperlikeFramebufferNotFound
    case propertyUnavailable(String)
    case writeFailed(property: String, code: kern_return_t)
    case paperlikeDisplayNotFound
    case ambiguousPaperlikeDisplays
    case displayUnavailable(String)
    case invalidCalibration
    case invalidGammaTable
    case gammaFailed(operation: String, code: CGError)

    public var errorDescription: String? {
        switch self {
        case .paperlikeFramebufferNotFound: "未找到 PaperLike 显示驱动。"
        case let .propertyUnavailable(name): "显示驱动未提供 \(name) 选项。"
        case let .writeFailed(property, code): "驱动选项 \(property) 写入失败（\(code)）。"
        case .paperlikeDisplayNotFound: "未找到 PaperLike 视频显示器。"
        case .ambiguousPaperlikeDisplays: "无法唯一识别目标 PaperLike，未修改显示设置。"
        case .displayUnavailable: "原显示器暂不可用，恢复备份仍保留。"
        case .invalidCalibration: "画面曲线参数无效。"
        case .invalidGammaTable: "无法读取有效的原始画面曲线，未写入新曲线。"
        case let .gammaFailed(operation, code): "系统画面曲线 \(operation) 失败（\(code.rawValue)）。"
        }
    }
}

public struct DisplayDriverDisplay: Sendable {
    public let id: CGDirectDisplayID
    public let stableID: String
    public let name: String

    public init(id: CGDirectDisplayID, stableID: String, name: String) {
        self.id = id
        self.stableID = stableID
        self.name = name
    }
}

public struct DisplayGammaTable: Sendable, Equatable {
    public let red: [CGGammaValue]
    public let green: [CGGammaValue]
    public let blue: [CGGammaValue]

    public init(red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    fileprivate var isValid: Bool {
        red.count >= 2 && red.count == green.count && red.count == blue.count
            && [red, green, blue].allSatisfy { $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }
    }
}

public protocol DisplayDriverBackend: Sendable {
    func readBoolean(_ property: String, for display: DisplayDriverDisplay) throws -> Bool
    func writeBoolean(_ value: Bool, property: String, for display: DisplayDriverDisplay) throws
    func displays() throws -> [DisplayDriverDisplay]
    func gammaTable(for displayID: CGDirectDisplayID) throws -> DisplayGammaTable
    func setGammaTable(_ table: DisplayGammaTable, for displayID: CGDirectDisplayID) throws
}

public extension DisplayDriverBackend {
    func displays() throws -> [DisplayDriverDisplay] {
        var count: UInt32 = 0
        var status = CGGetOnlineDisplayList(0, nil, &count)
        guard status == .success else { throw DisplayDriverError.gammaFailed(operation: "enumerate", code: status) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        status = CGGetOnlineDisplayList(count, &ids, &count)
        guard status == .success else { throw DisplayDriverError.gammaFailed(operation: "enumerate", code: status) }
        let products = displayProducts()
        return ids.prefix(Int(count)).compactMap { id in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let names = products.filter {
                $0.vendor == CGDisplayVendorNumber(id) && $0.product == CGDisplayModelNumber(id)
                    && ($0.serial == 0 || $0.serial == CGDisplaySerialNumber(id))
            }.map(\.name)
            return DisplayDriverDisplay(id: id, stableID: CFUUIDCreateString(nil, uuid) as String, name: names.first ?? "")
        }
    }

    func gammaTable(for displayID: CGDirectDisplayID) throws -> DisplayGammaTable {
        let capacity = CGDisplayGammaTableCapacity(displayID)
        guard capacity >= 2 else { throw DisplayDriverError.invalidGammaTable }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        let status = CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &count)
        guard status == .success else { throw DisplayDriverError.gammaFailed(operation: "read", code: status) }
        guard count >= 2 && count <= capacity else { throw DisplayDriverError.invalidGammaTable }
        return DisplayGammaTable(red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))), blue: Array(blue.prefix(Int(count))))
    }

    func setGammaTable(_ table: DisplayGammaTable, for displayID: CGDirectDisplayID) throws {
        guard table.isValid else { throw DisplayDriverError.invalidGammaTable }
        var red = table.red
        var green = table.green
        var blue = table.blue
        let status = CGSetDisplayTransferByTable(displayID, UInt32(red.count), &red, &green, &blue)
        guard status == .success else { throw DisplayDriverError.gammaFailed(operation: "write", code: status) }
    }
}

public final class DisplayDriverService: @unchecked Sendable {
    public static let shared = DisplayDriverService()

    private let lock = NSLock()
    private let backend: any DisplayDriverBackend
    private var originalValues: [String: [String: Bool]] = [:]

    private var originalGamma: [String: DisplayGammaTable] = [:]

    public convenience init() {
        self.init(backend: IOKitDisplayDriverBackend())
    }

    public init(backend: any DisplayDriverBackend) {
        self.backend = backend
    }

    public func findPaperlikeDisplayID() -> CGDirectDisplayID? {
        try? targetDisplay(in: backend.displays(), explicitID: nil).id
    }

    public func findPaperlikeRefreshRate() -> Double? {
        guard let displayID = findPaperlikeDisplayID() else {
            return nil
        }
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return nil
        }
        return mode.refreshRate
    }

    public func applyDisplayCalibration(
        saturation: Double,
        redThreshold: Double,
        greenThreshold: Double,
        blueThreshold: Double,
        contrastSlope: Double,
        isGrayscaleEnabled: Bool,
        targetDisplayID: CGDirectDisplayID? = nil
    ) throws {
        guard saturation.isFinite && (0...1).contains(saturation),
            [redThreshold, greenThreshold, blueThreshold].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
            contrastSlope.isFinite && contrastSlope > 0
        else { throw DisplayDriverError.invalidCalibration }
        lock.lock()
        defer { lock.unlock() }
        if !isGrayscaleEnabled && saturation == 0.5 {
            guard !originalGamma.isEmpty else { return }
            let displays = try backend.displays()
            if let targetDisplayID {
                let target = try targetDisplay(in: displays, explicitID: targetDisplayID)
                try restoreGamma(stableID: target.stableID, displays: displays)
            } else {
                try restoreGamma(displays: displays)
            }
            return
        }
        let target = try targetDisplay(in: backend.displays(), explicitID: targetDisplayID)
        if originalGamma[target.stableID] == nil {
            let table = try backend.gammaTable(for: target.id)
            guard table.isValid else { throw DisplayDriverError.invalidGammaTable }
            originalGamma[target.stableID] = table
        }
        guard let original = originalGamma[target.stableID] else { return }
        // Legacy saturation/grayscale names now represent tone contrast and channel curves, not RGB mixing.
        func channel(threshold: Double) -> [CGGammaValue] {
            let low = tanh(-contrastSlope * threshold / 2)
            let high = tanh(contrastSlope * (1 - threshold) / 2)
            return original.red.indices.map { index in
                let x = Double(index) / Double(original.red.count - 1)
                if index == 0 { return 0 }
                if index == original.red.count - 1 { return 1 }
                let value: Double
                if isGrayscaleEnabled {
                    let span = high - low
                    value = span > 1e-12 ? (tanh(contrastSlope * (x - threshold) / 2) - low) / span : x
                } else if saturation > 0.5 {
                    let t = (saturation - 0.5) * 2
                    value = (1 - t) * x + t * (3 * x * x - 2 * x * x * x)
                } else {
                    value = x + (0.5 - saturation) * 2 * x * (1 - x) * (1 - 2 * x)
                }
                return CGGammaValue(max(0, min(1, value)))
            }
        }
        try backend.setGammaTable(DisplayGammaTable(red: channel(threshold: redThreshold), green: channel(threshold: greenThreshold), blue: channel(threshold: blueThreshold)), for: target.id)
    }

    public func ditheringEnabled() throws -> Bool {
        try backend.readBoolean("enableDither", for: targetDisplay(in: backend.displays(), explicitID: nil))
    }

    public func setDitheringEnabled(_ enabled: Bool) throws {
        try setBoolean(enabled, property: "enableDither")
    }

    public func enhancementEnabled() throws -> Bool {
        try backend.readBoolean("uniformity2D", for: targetDisplay(in: backend.displays(), explicitID: nil))
    }

    public func setEnhancementEnabled(_ enabled: Bool) throws {
        try setBoolean(enabled, property: "uniformity2D")
    }

    public func restoreDithering() throws {
        try restore(property: "enableDither")
    }

    public func restoreDisplayCalibration() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !originalGamma.isEmpty else { return }
        try restoreGamma(displays: backend.displays())
    }

    public func restore() throws {
        lock.lock()
        let properties = Set(originalValues.values.flatMap(\.keys))
        lock.unlock()
        var firstError: Error?
        for property in properties {
            do { try restore(property: property) }
            catch { if firstError == nil { firstError = error } }
        }
        do { try restoreDisplayCalibration() }
        catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }

    private func targetDisplay(in displays: [DisplayDriverDisplay], explicitID: CGDirectDisplayID?) throws -> DisplayDriverDisplay {
        let candidates = displays.filter { display in
            explicitID.map { $0 == display.id } ?? display.name.localizedCaseInsensitiveContains("Paperlike")
        }
        guard !candidates.isEmpty else { throw DisplayDriverError.paperlikeDisplayNotFound }
        guard candidates.count == 1 else { throw DisplayDriverError.ambiguousPaperlikeDisplays }
        return candidates[0]
    }

    // Caller holds the lock; a backup is removed only after its original display accepts the restore.
    private func restoreGamma(stableID: String? = nil, displays: [DisplayDriverDisplay]) throws {
        let identities = stableID.map { [$0] } ?? Array(originalGamma.keys)
        var firstError: Error?
        for identity in identities {
            guard let table = originalGamma[identity] else { continue }
            do {
                let targets = displays.filter { $0.stableID == identity }
                guard targets.count == 1, let target = targets.first else { throw DisplayDriverError.displayUnavailable(identity) }
                try backend.setGammaTable(table, for: target.id)
                originalGamma.removeValue(forKey: identity)
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private func setBoolean(_ enabled: Bool, property: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let target = try targetDisplay(in: backend.displays(), explicitID: nil)
        if originalValues[target.stableID]?[property] == nil {
            originalValues[target.stableID, default: [:]][property] = try backend.readBoolean(property, for: target)
        }
        do {
            try backend.writeBoolean(enabled, property: property, for: target)
        } catch {
            try? restoreBoolean(property: property, identity: target.stableID, displays: [target])
            throw error
        }
    }

    private func restore(property: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let identities = originalValues.keys.filter { originalValues[$0]?[property] != nil }
        guard !identities.isEmpty else { return }
        let displays = try backend.displays()
        var firstError: Error?
        for identity in identities {
            do { try restoreBoolean(property: property, identity: identity, displays: displays) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    // Caller holds the lock. Missing targets and failed writes retain their original values.
    private func restoreBoolean(property: String, identity: String, displays: [DisplayDriverDisplay]) throws {
        guard let original = originalValues[identity]?[property] else { return }
        let matches = displays.filter { $0.stableID == identity }
        guard matches.count == 1, let target = matches.first else { throw DisplayDriverError.displayUnavailable(identity) }
        do {
            try backend.writeBoolean(original, property: property, for: target)
        } catch {
            // A rejected write may leave the property unchanged. Only a matching readback
            // from the original display proves that no further restoration is needed.
            guard (try? backend.readBoolean(property, for: target)) == original else { throw error }
        }
        originalValues[identity]?.removeValue(forKey: property)
        if originalValues[identity]?.isEmpty == true { originalValues.removeValue(forKey: identity) }
    }

}

private func displayProducts() -> [(vendor: UInt32, product: UInt32, serial: UInt32, name: String)] {
    var products: [(vendor: UInt32, product: UInt32, serial: UInt32, name: String)] = []
    for serviceClass in ["IODisplayConnect", "IOMobileFramebufferAP"] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS else { continue }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let info = IODisplayCreateInfoDictionary(entry, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any]
            let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            let product = attributes?["ProductAttributes"] as? [String: Any]
            let localizedNames = info?["DisplayProductName"] as? [String: String]
            let name = product?["ProductName"] as? String ?? localizedNames?.values.first
            let vendor = (product?["VendorID"] as? NSNumber) ?? (product?["LegacyManufacturerID"] as? NSNumber) ?? (info?["DisplayVendorID"] as? NSNumber)
            let model = (product?["ProductID"] as? NSNumber) ?? (info?["DisplayProductID"] as? NSNumber)
            let serial = (product?["SerialNumber"] as? NSNumber) ?? (info?["DisplaySerialNumber"] as? NSNumber)
            if let name, let vendor, let model {
                products.append((vendor.uint32Value, model.uint32Value, serial?.uint32Value ?? 0, name))
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }
    return products
}

private final class IOKitDisplayDriverBackend:
    DisplayDriverBackend,
    @unchecked Sendable
{
    func readBoolean(_ property: String, for display: DisplayDriverDisplay) throws -> Bool {
        let entry = try paperlikeFramebuffer(for: display)
        defer { IOObjectRelease(entry) }

        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            property as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool else {
            throw DisplayDriverError.propertyUnavailable(property)
        }
        return value
    }

    func writeBoolean(_ value: Bool, property: String, for display: DisplayDriverDisplay) throws {
        let entry = try paperlikeFramebuffer(for: display)
        defer { IOObjectRelease(entry) }

        let status = IORegistryEntrySetCFProperty(
            entry,
            property as CFString,
            value as CFBoolean
        )
        guard status == KERN_SUCCESS else {
            throw DisplayDriverError.writeFailed(
                property: property,
                code: status
            )
        }
    }

    private func paperlikeFramebuffer(for display: DisplayDriverDisplay) throws -> io_registry_entry_t {
        func hasOriginalIdentity() -> Bool {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue() else { return false }
            return CFUUIDCreateString(nil, uuid) as String == display.stableID
        }
        guard hasOriginalIdentity() else { throw DisplayDriverError.displayUnavailable(display.stableID) }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferAP"), &iterator) == KERN_SUCCESS else {
            throw DisplayDriverError.paperlikeFramebufferNotFound
        }
        defer { IOObjectRelease(iterator) }
        var matches: [io_registry_entry_t] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if Self.matches(entry, displayID: display.id) {
                matches.append(entry)
            } else {
                IOObjectRelease(entry)
            }
            entry = IOIteratorNext(iterator)
        }
        guard matches.count == 1, hasOriginalIdentity() else {
            matches.forEach { IOObjectRelease($0) }
            if matches.count > 1 { throw DisplayDriverError.ambiguousPaperlikeDisplays }
            throw DisplayDriverError.displayUnavailable(display.stableID)
        }
        return matches[0]
    }

    private static func matches(_ entry: io_registry_entry_t, displayID: CGDirectDisplayID) -> Bool {
        guard let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
              let product = attributes["ProductAttributes"] as? [String: Any],
              let name = product["ProductName"] as? String,
              name.localizedCaseInsensitiveContains("Paperlike13K") else { return false }
        let info = IODisplayCreateInfoDictionary(entry, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any]
        let vendor = (product["VendorID"] as? NSNumber) ?? (product["LegacyManufacturerID"] as? NSNumber) ?? (info?["DisplayVendorID"] as? NSNumber)
        let model = (product["ProductID"] as? NSNumber) ?? (info?["DisplayProductID"] as? NSNumber)
        let serial = ((product["SerialNumber"] as? NSNumber) ?? (info?["DisplaySerialNumber"] as? NSNumber))?.uint32Value ?? 0
        return vendor?.uint32Value == CGDisplayVendorNumber(displayID)
            && model?.uint32Value == CGDisplayModelNumber(displayID)
            && (serial == 0 || serial == CGDisplaySerialNumber(displayID))
    }
}
