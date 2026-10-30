import PaperlikeLocalization
import CoreGraphics
import Foundation

public enum TouchDisplaySelection: Equatable, Sendable, Codable {
    case automatic
    case display(CGDirectDisplayID)
    case stable(String)

    private enum CodingKeys: String, CodingKey {
        case mode
        case displayID
        case stableID
    }

    private enum Mode: String, Codable {
        case automatic
        case display
        case stable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .automatic:
            self = .automatic
        case .display:
            self = .display(try container.decode(CGDirectDisplayID.self, forKey: .displayID))
        case .stable:
            self = .stable(try container.decode(String.self, forKey: .stableID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode(Mode.automatic, forKey: .mode)
        case let .display(displayID):
            try container.encode(Mode.display, forKey: .mode)
            try container.encode(displayID, forKey: .displayID)
        case let .stable(stableID):
            try container.encode(Mode.stable, forKey: .mode)
            try container.encode(stableID, forKey: .stableID)
        }
    }
}

public struct TouchMappingSettings: Equatable, Sendable, Codable {
    public let isEnabled: Bool
    public let displaySelection: TouchDisplaySelection
    public let calibration: TouchCalibration
    public let calibrationByDisplay: [String: TouchCalibration]
    public let isManualCalibration: Bool
    public let isNaturalScrolling: Bool
    public let scrollSpeed: Double
    public let isInertialScrollEnabled: Bool
    public let inertiaFriction: Double
    public let isPinchToZoomEnabled: Bool
    public let isTwoFingerRightClickEnabled: Bool
    public let isSingleFingerScrollEnabled: Bool
    public let isCursorHiddenOnTouch: Bool

    public init(
        isEnabled: Bool = true,
        displaySelection: TouchDisplaySelection = .automatic,
        calibration: TouchCalibration = .default,
        calibrationByDisplay: [String: TouchCalibration] = [:],
        isManualCalibration: Bool? = nil,
        isNaturalScrolling: Bool = true,
        scrollSpeed: Double = 1.0,
        isInertialScrollEnabled: Bool = true,
        inertiaFriction: Double = 0.92,
        isPinchToZoomEnabled: Bool = true,
        isTwoFingerRightClickEnabled: Bool = true,
        isSingleFingerScrollEnabled: Bool = true,
        isCursorHiddenOnTouch: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.displaySelection = displaySelection
        self.calibration = calibration
        self.calibrationByDisplay = calibrationByDisplay
        self.isManualCalibration = isManualCalibration ?? (calibration != .default)
        self.isNaturalScrolling = isNaturalScrolling
        self.scrollSpeed = scrollSpeed
        self.isInertialScrollEnabled = isInertialScrollEnabled
        self.inertiaFriction = inertiaFriction
        self.isPinchToZoomEnabled = isPinchToZoomEnabled
        self.isTwoFingerRightClickEnabled = isTwoFingerRightClickEnabled
        self.isSingleFingerScrollEnabled = isSingleFingerScrollEnabled
        self.isCursorHiddenOnTouch = isCursorHiddenOnTouch
    }

    public func updating(
        isEnabled: Bool? = nil,
        displaySelection: TouchDisplaySelection? = nil,
        calibration: TouchCalibration? = nil,
        calibrationByDisplay: [String: TouchCalibration]? = nil,
        isManualCalibration: Bool? = nil,
        isNaturalScrolling: Bool? = nil,
        scrollSpeed: Double? = nil,
        isInertialScrollEnabled: Bool? = nil,
        inertiaFriction: Double? = nil,
        isPinchToZoomEnabled: Bool? = nil,
        isTwoFingerRightClickEnabled: Bool? = nil,
        isSingleFingerScrollEnabled: Bool? = nil,
        isCursorHiddenOnTouch: Bool? = nil
    ) -> TouchMappingSettings {
        TouchMappingSettings(
            isEnabled: isEnabled ?? self.isEnabled,
            displaySelection: displaySelection ?? self.displaySelection,
            calibration: calibration ?? self.calibration,
            calibrationByDisplay: calibrationByDisplay ?? self.calibrationByDisplay,
            isManualCalibration: isManualCalibration ?? self.isManualCalibration,
            isNaturalScrolling: isNaturalScrolling ?? self.isNaturalScrolling,
            scrollSpeed: scrollSpeed ?? self.scrollSpeed,
            isInertialScrollEnabled: isInertialScrollEnabled ?? self.isInertialScrollEnabled,
            inertiaFriction: inertiaFriction ?? self.inertiaFriction,
            isPinchToZoomEnabled: isPinchToZoomEnabled ?? self.isPinchToZoomEnabled,
            isTwoFingerRightClickEnabled: isTwoFingerRightClickEnabled ?? self.isTwoFingerRightClickEnabled,
            isSingleFingerScrollEnabled: isSingleFingerScrollEnabled ?? self.isSingleFingerScrollEnabled,
            isCursorHiddenOnTouch: isCursorHiddenOnTouch ?? self.isCursorHiddenOnTouch
        )
    }

    public static let `default` = TouchMappingSettings()

    // Independent touch module uses the same per-section budget as configuration backup.
    public static let maximumSectionBytes = 192 * 1024

    public func encodedForStorage() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumSectionBytes else {
            throw TouchSettingsSizeError()
        }
        return data
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case displaySelection
        case minX
        case maxX
        case minY
        case maxY
        case swapAxes
        case flipX
        case flipY
        case calibrationByDisplay
        case isManualCalibration
        case isNaturalScrolling
        case scrollSpeed
        case isInertialScrollEnabled
        case inertiaFriction
        case isPinchToZoomEnabled
        case isTwoFingerRightClickEnabled
        case isSingleFingerScrollEnabled
        case isCursorHiddenOnTouch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minX = try container.decode(Double.self, forKey: .minX)
        let maxX = try container.decode(Double.self, forKey: .maxX)
        let minY = try container.decode(Double.self, forKey: .minY)
        let maxY = try container.decode(Double.self, forKey: .maxY)
        let swapAxes = try container.decode(Bool.self, forKey: .swapAxes)
        let flipX = try container.decode(Bool.self, forKey: .flipX)
        let flipY = try container.decode(Bool.self, forKey: .flipY)
        guard let calibration = TouchCalibration(
            minX: minX,
            maxX: maxX,
            minY: minY,
            maxY: maxY,
            swapAxes: swapAxes,
            flipX: flipX,
            flipY: flipY
        ) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid touch calibration")
            )
        }
        self.init(
            isEnabled: try container.decode(Bool.self, forKey: .isEnabled),
            displaySelection: try container.decode(TouchDisplaySelection.self, forKey: .displaySelection),
            calibration: calibration,
            calibrationByDisplay: try container.decodeIfPresent([String: TouchCalibration].self, forKey: .calibrationByDisplay) ?? [:],
            isManualCalibration: try container.decodeIfPresent(Bool.self, forKey: .isManualCalibration) ?? (calibration != .default),
            isNaturalScrolling: try container.decodeIfPresent(Bool.self, forKey: .isNaturalScrolling) ?? true,
            scrollSpeed: try container.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? 1.0,
            isInertialScrollEnabled: try container.decodeIfPresent(Bool.self, forKey: .isInertialScrollEnabled) ?? true,
            inertiaFriction: try container.decodeIfPresent(Double.self, forKey: .inertiaFriction) ?? 0.92,
            isPinchToZoomEnabled: try container.decodeIfPresent(Bool.self, forKey: .isPinchToZoomEnabled) ?? true,
            isTwoFingerRightClickEnabled: try container.decodeIfPresent(Bool.self, forKey: .isTwoFingerRightClickEnabled) ?? true,
            isSingleFingerScrollEnabled: try container.decodeIfPresent(Bool.self, forKey: .isSingleFingerScrollEnabled) ?? true,
            isCursorHiddenOnTouch: try container.decodeIfPresent(Bool.self, forKey: .isCursorHiddenOnTouch) ?? true
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(displaySelection, forKey: .displaySelection)
        try container.encode(calibration.minX, forKey: .minX)
        try container.encode(calibration.maxX, forKey: .maxX)
        try container.encode(calibration.minY, forKey: .minY)
        try container.encode(calibration.maxY, forKey: .maxY)
        try container.encode(calibration.swapAxes, forKey: .swapAxes)
        try container.encode(calibration.flipX, forKey: .flipX)
        try container.encode(calibration.flipY, forKey: .flipY)
        try container.encode(calibrationByDisplay, forKey: .calibrationByDisplay)
        try container.encode(isManualCalibration, forKey: .isManualCalibration)
        try container.encode(isNaturalScrolling, forKey: .isNaturalScrolling)
        try container.encode(scrollSpeed, forKey: .scrollSpeed)
        try container.encode(isInertialScrollEnabled, forKey: .isInertialScrollEnabled)
        try container.encode(inertiaFriction, forKey: .inertiaFriction)
        try container.encode(isPinchToZoomEnabled, forKey: .isPinchToZoomEnabled)
        try container.encode(isTwoFingerRightClickEnabled, forKey: .isTwoFingerRightClickEnabled)
        try container.encode(isSingleFingerScrollEnabled, forKey: .isSingleFingerScrollEnabled)
        try container.encode(isCursorHiddenOnTouch, forKey: .isCursorHiddenOnTouch)
    }
}

private struct TouchSettingsSizeError: LocalizedError {
    var errorDescription: String? { L("触控校准数据过多，未保存或应用此次更改。") }
}

@MainActor
public final class TouchSettingsStore {
    public static let storageKey = "PaperLikeNative.TouchMappingSettings"
    public static let corruptBackupKey = "PaperLikeNative.TouchMappingSettings.CorruptBackup"

    private let defaults: UserDefaults
    public private(set) var saveError: String?
    public private(set) var recoveredCorruptData = false
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> TouchMappingSettings {
        guard let raw = defaults.object(forKey: Self.storageKey) else { return .default }
        guard let data = raw as? Data,
              let settings = try? decoder.decode(TouchMappingSettings.self, from: data)
        else {
            recoveredCorruptData = true
            if defaults.object(forKey: Self.corruptBackupKey) == nil {
                defaults.set(raw, forKey: Self.corruptBackupKey)
            }
            return TouchMappingSettings(isEnabled: false)
        }
        return settings
    }

    @discardableResult
    public func save(_ settings: TouchMappingSettings) -> Bool {
        do {
            let data = try settings.encodedForStorage()
            defaults.set(data, forKey: Self.storageKey)
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func restoreDefaults() -> TouchMappingSettings {
        let settings = TouchMappingSettings.default
        save(settings)
        return settings
    }
}
