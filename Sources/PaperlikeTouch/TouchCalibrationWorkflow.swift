import CoreGraphics
import Foundation

public enum TouchCalibrationCorner: Int, CaseIterable, Equatable, Sendable {
    case topLeft
    case topRight
    case bottomRight
    case bottomLeft
}

public enum TouchCalibrationCaptureError: Error, Equatable, Sendable {
    case singleContactRequired
    case duplicatePoint
    case invalidGeometry
    case alreadyCompleted
}

public enum TouchCalibrationCaptureResult: Equatable, Sendable {
    case accepted(next: TouchCalibrationCorner)
    case completed(TouchCalibration)
    case rejected(TouchCalibrationCaptureError)
}

public struct TouchCalibrationWorkflow: Equatable, Sendable {
    public private(set) var points: [CGPoint] = []
    public private(set) var calibration: TouchCalibration?

    public init() {}

    public var nextCorner: TouchCalibrationCorner? {
        guard calibration == nil, points.count < TouchCalibrationCorner.allCases.count else {
            return nil
        }
        return TouchCalibrationCorner(rawValue: points.count)
    }

    public mutating func capture(_ frame: TouchFrame) -> TouchCalibrationCaptureResult {
        guard calibration == nil else {
            return .rejected(.alreadyCompleted)
        }
        let activeContacts = frame.contacts.filter(\.isTouching)
        guard activeContacts.count == 1, let contact = activeContacts.first else {
            return .rejected(.singleContactRequired)
        }

        let point = CGPoint(x: Double(contact.x), y: Double(contact.y))
        let isDuplicate = points.contains { existing in
            hypot(existing.x - point.x, existing.y - point.y) <= 32
        }
        guard !isDuplicate else {
            return .rejected(.duplicatePoint)
        }

        points.append(point)
        guard points.count == TouchCalibrationCorner.allCases.count else {
            return .accepted(next: TouchCalibrationCorner(rawValue: points.count)!)
        }

        guard let computed = Self.makeCalibration(points: points) else {
            points.removeLast()
            return .rejected(.invalidGeometry)
        }
        calibration = computed
        return .completed(computed)
    }

    public mutating func reset() {
        points.removeAll(keepingCapacity: true)
        calibration = nil
    }

    private static func makeCalibration(points: [CGPoint]) -> TouchCalibration? {
        guard points.count == 4 else {
            return nil
        }
        let topLeft = points[0]
        let topRight = points[1]
        let bottomRight = points[2]
        let bottomLeft = points[3]

        let horizontal = CGPoint(
            x: average(topRight.x, bottomRight.x) - average(topLeft.x, bottomLeft.x),
            y: average(topRight.y, bottomRight.y) - average(topLeft.y, bottomLeft.y)
        )
        let vertical = CGPoint(
            x: average(bottomLeft.x, bottomRight.x) - average(topLeft.x, topRight.x),
            y: average(bottomLeft.y, bottomRight.y) - average(topLeft.y, topRight.y)
        )
        let swapAxes = abs(horizontal.y) > abs(horizontal.x)

        guard isDominant(horizontal, useY: swapAxes),
              isDominant(vertical, useY: !swapAxes) else {
            return nil
        }

        let topEdge = delta(from: topLeft, to: topRight)
        let bottomEdge = delta(from: bottomLeft, to: bottomRight)
        let leftEdge = delta(from: topLeft, to: bottomLeft)
        let rightEdge = delta(from: topRight, to: bottomRight)
        let horizontalComponents = [
            component(topEdge, useY: swapAxes),
            component(bottomEdge, useY: swapAxes)
        ]
        let verticalComponents = [
            component(leftEdge, useY: !swapAxes),
            component(rightEdge, useY: !swapAxes)
        ]
        guard componentsAreConsistent(horizontalComponents),
              componentsAreConsistent(verticalComponents) else {
            return nil
        }

        let rawXEdges: (CGFloat, CGFloat)
        let rawYEdges: (CGFloat, CGFloat)
        if swapAxes {
            rawXEdges = (
                average(topLeft.x, topRight.x),
                average(bottomLeft.x, bottomRight.x)
            )
            rawYEdges = (
                average(topLeft.y, bottomLeft.y),
                average(topRight.y, bottomRight.y)
            )
        } else {
            rawXEdges = (
                average(topLeft.x, bottomLeft.x),
                average(topRight.x, bottomRight.x)
            )
            rawYEdges = (
                average(topLeft.y, topRight.y),
                average(bottomLeft.y, bottomRight.y)
            )
        }

        return TouchCalibration(
            minX: min(rawXEdges.0, rawXEdges.1),
            maxX: max(rawXEdges.0, rawXEdges.1),
            minY: min(rawYEdges.0, rawYEdges.1),
            maxY: max(rawYEdges.0, rawYEdges.1),
            swapAxes: swapAxes,
            flipX: component(horizontal, useY: swapAxes) < 0,
            flipY: component(vertical, useY: !swapAxes) < 0
        )
    }

    private static func average(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        (first + second) / 2
    }

    private static func delta(from start: CGPoint, to end: CGPoint) -> CGPoint {
        CGPoint(x: end.x - start.x, y: end.y - start.y)
    }

    private static func component(_ point: CGPoint, useY: Bool) -> CGFloat {
        useY ? point.y : point.x
    }

    private static func isDominant(_ vector: CGPoint, useY: Bool) -> Bool {
        let dominant = abs(component(vector, useY: useY))
        let minor = abs(component(vector, useY: !useY))
        return dominant >= 512 && dominant >= minor * 2
    }

    private static func componentsAreConsistent(_ values: [CGFloat]) -> Bool {
        guard values.allSatisfy({ abs($0) >= 512 }), let first = values.first else {
            return false
        }
        return values.dropFirst().allSatisfy { value in
            (value < 0) == (first < 0)
        }
    }
}
