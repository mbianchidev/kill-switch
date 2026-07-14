// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KillSwitch",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "DevCleanupCore",
            path: "Sources/DevCleanupCore"
        ),
        .target(
            name: "KeepAwakeCore",
            path: "Sources/KeepAwakeCore"
        ),
        .executableTarget(
            name: "KillSwitch",
            dependencies: ["DevCleanupCore", "KeepAwakeCore"],
            path: "Sources/KillSwitch"
        ),
        .executableTarget(
            name: "DevCleanupCoreChecks",
            dependencies: ["DevCleanupCore"],
            path: "Tests/DevCleanupCoreChecks"
        )
    ]
)
