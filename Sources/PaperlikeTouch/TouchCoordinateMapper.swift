import CoreGraphics

public enum TouchCoordinateMapper {
    public static func map(
        _ contact: TouchContact,
        calibration: TouchCalibration,
        display: TouchTargetDisplay
    ) -> CGPoint? {
        let bounds = display.bounds
        guard bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite else {
            return nil
        }

        let calibratedX = min(max(Double(contact.x), calibration.minX), calibration.maxX)
        let calibratedY = min(max(Double(contact.y), calibration.minY), calibration.maxY)
        var normalizedX = (calibratedX - calibration.minX) / (calibration.maxX - calibration.minX)
        var normalizedY = (calibratedY - calibration.minY) / (calibration.maxY - calibration.minY)

        if calibration.swapAxes {
            swap(&normalizedX, &normalizedY)
        }
        if calibration.flipX {
            normalizedX = 1 - normalizedX
        }
        if calibration.flipY {
            normalizedY = 1 - normalizedY
        }

        switch ((display.rotation % 360) + 360) % 360 {
        case 90:
            (normalizedX, normalizedY) = (1 - normalizedY, normalizedX)
        case 180:
            (normalizedX, normalizedY) = (1 - normalizedX, 1 - normalizedY)
        case 270:
            (normalizedX, normalizedY) = (normalizedY, 1 - normalizedX)
        default:
            break
        }

        let x = bounds.origin.x + (CGFloat(normalizedX) * bounds.width)
        let y = bounds.origin.y + (CGFloat(normalizedY) * bounds.height)
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }
}
