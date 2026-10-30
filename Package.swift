// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PaperLike Native",
    defaultLocalization: "en",
    platforms: [.macOS("15.4")],
    products: [
        .library(name: "PaperlikeProtocol", targets: ["PaperlikeProtocol"]),
        .library(name: "SerialTransport", targets: ["SerialTransport"]),
        .library(name: "PaperlikeCore", targets: ["PaperlikeCore"]),
        .library(name: "PaperlikeTouch", targets: ["PaperlikeTouch"]),
        .library(name: "PaperLikeNativeUI", targets: ["PaperLikeNativeUI"]),
        .executable(name: "PaperLikeNative", targets: ["PaperLikeNative"]),
        .executable(name: "PaperlikeProbe", targets: ["PaperlikeProbe"]),
        .executable(name: "PaperlikeTests", targets: ["PaperlikeTests"])
    ],
    targets: [
        .target(name: "PaperlikeLocalization", resources: [.process("Resources")]),
        .target(name: "PaperlikeProtocol", dependencies: ["PaperlikeLocalization"]),
        .target(name: "SerialTransport", dependencies: ["PaperlikeLocalization"]),
        .target(
            name: "PaperlikeCore",
            dependencies: ["PaperlikeProtocol", "SerialTransport", "PaperlikeLocalization"]
        ),
        .target(name: "PaperlikeTouch", dependencies: ["PaperlikeLocalization"]),
        .target(
            name: "PaperLikeNativeUI",
            dependencies: ["PaperlikeCore", "SerialTransport", "PaperlikeTouch", "PaperlikeLocalization"]
        ),
        .executableTarget(
            name: "PaperLikeNative",
            dependencies: ["PaperLikeNativeUI", "PaperlikeLocalization"]
        ),
        .executableTarget(
            name: "PaperlikeProbe",
            dependencies: [
                "PaperlikeCore",
                "PaperlikeProtocol",
                "SerialTransport"
            ]
        ),
        .executableTarget(
            name: "PaperlikeTests",
            dependencies: [
                "PaperlikeLocalization",
                "PaperlikeProtocol",
                "SerialTransport",
                "PaperlikeCore",
                "PaperlikeTouch",
                "PaperLikeNativeUI"
            ],
            path: "Tests/PaperlikeTests"
        )
    ]
)
