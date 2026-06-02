// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KillSwitch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "KillSwitch",
            path: "Sources/KillSwitch"
        )
    ]
)
