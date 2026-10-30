// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PaperLike Native",
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
        .target(name: "PaperlikeProtocol"),
        .target(name: "SerialTransport"),
        .target(
            name: "PaperlikeCore",
            dependencies: ["PaperlikeProtocol", "SerialTransport"]
        ),
        .target(name: "PaperlikeTouch"),
        .target(
            name: "PaperLikeNativeUI",
            dependencies: ["PaperlikeCore", "SerialTransport", "PaperlikeTouch"]
        ),
        .executableTarget(
            name: "PaperLikeNative",
            dependencies: ["PaperLikeNativeUI"]
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
