import Foundation
import PaperlikeTouch

func touchCalibrationWorkflowTests() -> [TestCase] {
    [
        TestCase("TouchCalibrationWorkflow.computesBoundsFromOrderedCorners") {
            var workflow = TouchCalibrationWorkflow()

            _ = workflow.capture(calibrationFrame(x: 100, y: 120))
            _ = workflow.capture(calibrationFrame(x: 3_990, y: 110))
            _ = workflow.capture(calibrationFrame(x: 4_000, y: 3_970))
            let result = workflow.capture(calibrationFrame(x: 90, y: 3_980))

            let expected = TouchCalibration(
                minX: 95,
                maxX: 3_995,
                minY: 115,
                maxY: 3_975
            )!
            try expectEqual(result, .completed(expected))
            try expectEqual(workflow.calibration, expected)
        },
        TestCase("TouchCalibrationWorkflow.detectsSwappedAndFlippedAxes") {
            var workflow = TouchCalibrationWorkflow()

            _ = workflow.capture(calibrationFrame(x: 4_000, y: 100))
            _ = workflow.capture(calibrationFrame(x: 3_990, y: 4_000))
            _ = workflow.capture(calibrationFrame(x: 100, y: 3_990))
            let result = workflow.capture(calibrationFrame(x: 110, y: 90))

            let expected = TouchCalibration(
                minX: 105,
                maxX: 3_995,
                minY: 95,
                maxY: 3_995,
                swapAxes: true,
                flipY: true
            )!
            try expectEqual(result, .completed(expected))
        },
        TestCase("TouchCalibrationWorkflow.rejectsRepeatAndMultipleContactsWithoutAdvancing") {
            var workflow = TouchCalibrationWorkflow()
            let first = calibrationFrame(x: 100, y: 100)

            try expectEqual(workflow.capture(first), .accepted(next: .topRight))
            try expectEqual(
                workflow.capture(calibrationFrame(x: 108, y: 112)),
                .rejected(.duplicatePoint)
            )
            try expectEqual(
                workflow.capture(
                    calibrationFrame(
                        contacts: [
                            TouchContact(id: 1, x: 3_900, y: 100, width: 10, isTouching: true),
                            TouchContact(id: 2, x: 3_800, y: 120, width: 10, isTouching: true)
                        ]
                    )
                ),
                .rejected(.singleContactRequired)
            )
            try expectEqual(workflow.points.count, 1)
            try expectEqual(workflow.nextCorner, .topRight)
        },
        TestCase("TouchCalibrationWorkflow.rejectsAbnormalFinalPointAndCanReset") {
            var workflow = TouchCalibrationWorkflow()
            _ = workflow.capture(calibrationFrame(x: 100, y: 100))
            _ = workflow.capture(calibrationFrame(x: 4_000, y: 100))
            _ = workflow.capture(calibrationFrame(x: 3_900, y: 4_000))

            try expectEqual(
                workflow.capture(calibrationFrame(x: 3_800, y: 200)),
                .rejected(.invalidGeometry)
            )
            try expectEqual(workflow.points.count, 3)
            try expectEqual(workflow.nextCorner, .bottomLeft)

            workflow.reset()

            try expectEqual(workflow.points, [])
            try expectEqual(workflow.nextCorner, .topLeft)
            try expectEqual(workflow.calibration, nil)
        }
    ]
}

private func calibrationFrame(x: UInt16, y: UInt16) -> TouchFrame {
    calibrationFrame(
        contacts: [
            TouchContact(id: 1, x: x, y: y, width: 10, isTouching: true)
        ]
    )
}

private func calibrationFrame(contacts: [TouchContact]) -> TouchFrame {
    TouchFrame(contacts: contacts, scanTime: 0, timestamp: 1)
}
