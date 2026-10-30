import PaperlikeCore

func connectionPresentationTests() -> [TestCase] {
    [
        TestCase("ConnectionPresentation.connected") {
            let profile = PaperlikeDeviceProfile(
                mcuVersion: 0x30,
                familyIdentifier: 0x01
            )!
            let state = ConnectionState.connected(
                name: profile.displayName,
                state: DeviceState(
                    profile: profile,
                    mode: .text,
                    threshold: 1,
                    speed: nil,
                    frontLightMode: 3,
                    brightness: 39,
                    temperature: 86
                )
            )
            let value = ConnectionPresentation(state: state)

            try expectEqual(value.symbolName, "display")
            try expectEqual(value.menuBarIconName, "PaperlikeMenuConnected")
            try expectEqual(
                value.accessibilityLabel,
                "显示器控制，已连接"
            )
            try expectEqual(
                value.detail(serialPath: "/dev/cu.usbserial-120"),
                "PaperLike 13.3K 彩色版（有前光）\n/dev/cu.usbserial-120"
            )
        },
        TestCase("ConnectionPresentation.disconnected") {
            let value = ConnectionPresentation(state: .disconnected)

            try expectEqual(
                value.symbolName,
                "display.trianglebadge.exclamationmark"
            )
            try expectEqual(value.menuBarIconName, "PaperlikeMenuDisconnected")
            try expectEqual(value.accessibilityLabel, "显示器控制，未连接")
        },
        TestCase("ConnectionPresentation.connecting") {
            let value = ConnectionPresentation(
                state: .connecting(path: "/dev/cu.test")
            )

            try expectEqual(value.showsProgress, true)
            try expectEqual(value.menuBarIconName, "PaperlikeMenuConnecting")
            try expectEqual(value.accessibilityLabel, "显示器控制，正在连接")
            try expectEqual(
                value.detail(serialPath: nil),
                "/dev/cu.test"
            )
        },
        TestCase("ConnectionPresentation.failure") {
            let value = ConnectionPresentation(
                state: .failed(message: "连接失败")
            )

            try expectEqual(value.allowsReconnect, true)
            try expectEqual(value.menuBarIconName, "PaperlikeMenuError")
            try expectEqual(value.accessibilityLabel, "显示器控制，连接异常")
        },
        TestCase("ConnectionPresentation.unsupportedUsesErrorArtwork") {
            let value = ConnectionPresentation(
                state: .unsupported(identifier: "unknown")
            )
            try expectEqual(value.menuBarIconName, "PaperlikeMenuError")
        }
    ]
}
