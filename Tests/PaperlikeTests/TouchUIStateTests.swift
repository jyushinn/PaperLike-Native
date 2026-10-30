import PaperLikeNativeUI
import PaperlikeTouch

func touchUIStateTests() -> [TestCase] {
    [
        TestCase("TouchUIState.enablesMappingOnlyWhenEveryTouchGateIsReady") {
            let display = TouchDisplay(
                id: 11,
                name: "Paperlike13K Color",
                bounds: .init(x: 0, y: 0, width: 1_920, height: 1_080)
            )
            let ready = TouchUIState(
                status: .ready,
                isEnabled: true,
                isTesting: false,
                isTouchDeviceConnected: true,
                isAccessibilityTrusted: true,
                targetDisplay: display
            )
            let noDisplay = TouchUIState(
                status: .displaySelectionRequired,
                isEnabled: false,
                isTesting: false,
                isTouchDeviceConnected: true,
                isAccessibilityTrusted: true,
                targetDisplay: nil
            )

            try expectEqual(ready.canEnable, true)
            try expectEqual(ready.isMappingActive, true)
            try expectEqual(noDisplay.canEnable, false)
            try expectEqual(noDisplay.isMappingActive, false)
        },
        TestCase("TouchUIState.testModeAndMissingHIDAreNeverActiveMapping") {
            let testing = TouchUIState(
                status: .testing,
                isEnabled: true,
                isTesting: true,
                isTouchDeviceConnected: true,
                isAccessibilityTrusted: false,
                targetDisplay: nil
            )
            let unsupported = TouchUIState(
                status: .deviceUnavailable,
                isEnabled: false,
                isTesting: false,
                isTouchDeviceConnected: false,
                isAccessibilityTrusted: true,
                targetDisplay: nil
            )
            let disconnectedWhileTesting = TouchUIState(
                status: .deviceUnavailable,
                isEnabled: false,
                isTesting: true,
                isTouchDeviceConnected: false,
                isAccessibilityTrusted: false,
                targetDisplay: nil
            )

            try expectEqual(testing.canEnable, false)
            try expectEqual(testing.isMappingActive, false)
            try expectEqual(unsupported.canToggleTesting, false)
            try expectEqual(disconnectedWhileTesting.canToggleTesting, true)
            try expect(unsupported.statusText.contains("不支持"), "missing HID is shown as unsupported")
            try expect(
                unsupported.detailText.contains("串口控制不受影响"),
                "missing touch HID does not imply serial failure"
            )
        }
    ]
}
