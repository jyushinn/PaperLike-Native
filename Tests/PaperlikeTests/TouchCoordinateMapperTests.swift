import CoreGraphics
import PaperlikeTouch

func touchCoordinateMapperTests() -> [TestCase] {
    [
        TestCase("TouchCoordinateMapperTests.clipsCoordinatesToCalibrationBounds") {
            let point = TouchCoordinateMapper.map(
                TouchContact(id: 1, x: 4096, y: 0, width: 20, isTouching: true),
                calibration: .default,
                display: TouchTargetDisplay(bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
            )

            try expectEqual(point, CGPoint(x: 200, y: 0))
        },
        TestCase("TouchCoordinateMapperTests.appliesCalibrationInsets") {
            let calibration = TouchCalibration(
                minX: 100, maxX: 1100,
                minY: 200, maxY: 1200
            )
            let point = TouchCoordinateMapper.map(
                TouchContact(id: 1, x: 600, y: 700, width: 20, isTouching: true),
                calibration: calibration!,
                display: TouchTargetDisplay(bounds: CGRect(x: 100, y: 200, width: 1_000, height: 500))
            )

            try expectEqual(point, CGPoint(x: 600, y: 450))
        },
        TestCase("TouchCoordinateMapperTests.appliesAxisSwap") {
            let calibration = TouchCalibration(
                minX: 0, maxX: 4096,
                minY: 0, maxY: 4096,
                swapAxes: true
            )
            let point = TouchCoordinateMapper.map(
                TouchContact(id: 1, x: 1024, y: 3072, width: 20, isTouching: true),
                calibration: calibration!,
                display: TouchTargetDisplay(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
            )

            try expectEqual(point, CGPoint(x: 75, y: 25))
        },
        TestCase("TouchCoordinateMapperTests.appliesXAndYFlips") {
            let calibration = TouchCalibration(
                minX: 0, maxX: 4096,
                minY: 0, maxY: 4096,
                flipX: true,
                flipY: true
            )
            let point = TouchCoordinateMapper.map(
                TouchContact(id: 1, x: 1024, y: 3072, width: 20, isTouching: true),
                calibration: calibration!,
                display: TouchTargetDisplay(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
            )

            try expectEqual(point, CGPoint(x: 75, y: 25))
        },
        TestCase("TouchCoordinateMapperTests.respectsNegativeQuartzDisplayOrigin") {
            let point = TouchCoordinateMapper.map(
                TouchContact(id: 1, x: 2048, y: 1024, width: 20, isTouching: true),
                calibration: .default,
                display: TouchTargetDisplay(bounds: CGRect(x: -1_920, y: -1_080, width: 1_920, height: 1_080))
            )

            try expectEqual(point, CGPoint(x: -960, y: -810))
        },
        TestCase("TouchCoordinateMapperTests.appliesDisplayRotationOnce") {
            let contact = TouchContact(id: 1, x: 1024, y: 3072, width: 20, isTouching: true)
            let display = TouchTargetDisplay(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), rotation: 90)
            let first = TouchCoordinateMapper.map(contact, calibration: .default, display: display)
            let second = TouchCoordinateMapper.map(contact, calibration: .default, display: display)

            try expectEqual(first, CGPoint(x: 25, y: 25))
            try expectEqual(second, first)
        },
        TestCase("TouchCoordinateMapperTests.rejectsInvalidCalibration") {
            let calibration = TouchCalibration(
                minX: 100, maxX: 100,
                minY: 0, maxY: 4096
            )

            try expectEqual(calibration, nil)
        },
        TestCase("TouchCalibration.acceptsOnlyUsableHIDLogicalBounds") {
            try expectEqual(
                TouchCalibration.hidLogicalBounds(minX: 100, maxX: 4_000, minY: 200, maxY: 3_800),
                TouchCalibration(minX: 100, maxX: 4_000, minY: 200, maxY: 3_800)
            )
            try expectEqual(TouchCalibration.hidLogicalBounds(minX: -1, maxX: 4_000, minY: 0, maxY: 4_000), nil)
            try expectEqual(TouchCalibration.hidLogicalBounds(minX: 0, maxX: 0, minY: 0, maxY: 4_000), nil)
            try expectEqual(TouchCalibration.hidLogicalBounds(minX: 0, maxX: 70_000, minY: 0, maxY: 4_000), nil)
        },
        TestCase("TouchCoordinateMapperTests.rejectsNonFiniteDisplayGeometry") {
            let point = TouchCoordinateMapper.map(
                TouchContact(id: 1, x: 0, y: 0, width: 20, isTouching: true),
                calibration: .default,
                display: TouchTargetDisplay(bounds: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100))
            )

            try expectEqual(point, nil)
        }
    ]
}
