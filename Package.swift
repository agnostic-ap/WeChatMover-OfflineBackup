// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WeChatMover",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WeChatMover",
            path: "Sources/WeChatMover"
        ),
        .testTarget(
            name: "WeChatMoverTests",
            dependencies: ["WeChatMover"],
            path: "Tests/WeChatMoverTests"
        )
    ]
)
