// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KillSwitch",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "KeepAwakeCore",
            path: "Sources/KeepAwakeCore"
        ),
        .executableTarget(
            name: "KillSwitch",
            dependencies: ["KeepAwakeCore"],
            path: "Sources/KillSwitch"
        )
    ]
)
