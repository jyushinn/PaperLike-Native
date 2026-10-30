import CoreGraphics
import Foundation

public struct TouchDeviceDescriptor: Equatable, Sendable {
    public let vendorID: UInt16
    public let productID: UInt16
    public let usagePage: UInt16
    public let usage: UInt16
    public let reportID: UInt8
    public let contactSlotCount: Int
    public let contactSlotByteCount: Int
    public let reportByteCount: Int
    public let coordinateMaximum: UInt16

    public init(
        vendorID: UInt16,
        productID: UInt16,
        usagePage: UInt16,
        usage: UInt16,
        reportID: UInt8,
        contactSlotCount: Int,
        contactSlotByteCount: Int,
        reportByteCount: Int,
        coordinateMaximum: UInt16
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.usagePage = usagePage
        self.usage = usage
        self.reportID = reportID
        self.contactSlotCount = contactSlotCount
        self.contactSlotByteCount = contactSlotByteCount
        self.reportByteCount = reportByteCount
        self.coordinateMaximum = coordinateMaximum
    }

    public static let paperLike13KColor = TouchDeviceDescriptor(
        vendorID: 0x1A86,
        productID: 0xE5E3,
        usagePage: 13,
        usage: 4,
        reportID: 1,
        contactSlotCount: 10,
        contactSlotByteCount: 8,
        reportByteCount: 84,
        coordinateMaximum: 4096
    )
}

public struct TouchContact: Equatable, Sendable {
    public let id: UInt8
    public let x: UInt16
    public let y: UInt16
    public let width: UInt8
    public let isTouching: Bool

    public init(id: UInt8, x: UInt16, y: UInt16, width: UInt8, isTouching: Bool) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.isTouching = isTouching
    }
}

public struct TouchFrame: Equatable, Sendable {
    public let contacts: [TouchContact]
    public let scanTime: UInt16
    public let timestamp: TimeInterval

    public init(contacts: [TouchContact], scanTime: UInt16, timestamp: TimeInterval) {
        self.contacts = contacts
        self.scanTime = scanTime
        self.timestamp = timestamp
    }
}

public enum TouchReportError: Error, Equatable, Sendable {
    case invalidReportID(UInt8)
    case invalidByteCount(Int)
    case contactCountOutOfRange(UInt8)
    case duplicateContactID(UInt8)
    case coordinateOutOfRange(x: UInt16, y: UInt16)
    case activeContactCountMismatch(expected: UInt8, actual: Int)
}

public struct TouchDiagnosticsSnapshot: Equatable, Sendable {
    public var gestureState: String
    public var contactCount: Int
    public var contactsDescription: String
    public var twoFingerDistance: CGFloat
    public var centroid: CGPoint
    public var velocity: CGPoint
    public var speed: CGFloat
    public var isInertiaActive: Bool
    public var inertiaVelocity: CGPoint
    public var lastAction: String

    public init(
        gestureState: String = "空闲",
        contactCount: Int = 0,
        contactsDescription: String = "无触控输入",
        twoFingerDistance: CGFloat = 0,
        centroid: CGPoint = .zero,
        velocity: CGPoint = .zero,
        speed: CGFloat = 0,
        isInertiaActive: Bool = false,
        inertiaVelocity: CGPoint = .zero,
        lastAction: String = "等待手势"
    ) {
        self.gestureState = gestureState
        self.contactCount = contactCount
        self.contactsDescription = contactsDescription
        self.twoFingerDistance = twoFingerDistance
        self.centroid = centroid
        self.velocity = velocity
        self.speed = speed
        self.isInertiaActive = isInertiaActive
        self.inertiaVelocity = inertiaVelocity
        self.lastAction = lastAction
    }
}

public struct TouchCalibration: Equatable, Sendable, Codable {
    public let minX: Double
    public let maxX: Double
    public let minY: Double
    public let maxY: Double
    public let swapAxes: Bool
    public let flipX: Bool
    public let flipY: Bool

    public init?(
        minX: Double,
        maxX: Double,
        minY: Double,
        maxY: Double,
        swapAxes: Bool = false,
        flipX: Bool = false,
        flipY: Bool = false
    ) {
        guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite,
              maxX > minX, maxY > minY else {
            return nil
        }

        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.swapAxes = swapAxes
        self.flipX = flipX
        self.flipY = flipY
    }

    public static let `default` = TouchCalibration(
        minX: 0,
        maxX: 4096,
        minY: 0,
        maxY: 4096
    )!

    public static func hidLogicalBounds(minX: Int, maxX: Int, minY: Int, maxY: Int) -> TouchCalibration? {
        guard minX >= 0, minY >= 0,
              maxX <= Int(UInt16.max), maxY <= Int(UInt16.max) else { return nil }
        return TouchCalibration(minX: Double(minX), maxX: Double(maxX), minY: Double(minY), maxY: Double(maxY))
    }

    private enum CodingKeys: String, CodingKey { case minX, maxX, minY, maxY, swapAxes, flipX, flipY }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let calibration = TouchCalibration(
            minX: try values.decode(Double.self, forKey: .minX),
            maxX: try values.decode(Double.self, forKey: .maxX),
            minY: try values.decode(Double.self, forKey: .minY),
            maxY: try values.decode(Double.self, forKey: .maxY),
            swapAxes: try values.decode(Bool.self, forKey: .swapAxes),
            flipX: try values.decode(Bool.self, forKey: .flipX),
            flipY: try values.decode(Bool.self, forKey: .flipY)
        ) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid touch calibration"))
        }
        self = calibration
    }
}

public struct TouchTargetDisplay: Equatable, Sendable {
    public let bounds: CGRect
    public let rotation: Int

    public init(bounds: CGRect, rotation: Int = 0) {
        self.bounds = bounds
        self.rotation = rotation
    }
}
