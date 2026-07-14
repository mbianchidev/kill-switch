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
        .target(
            name: "SystemMetricsCore",
            path: "Sources/SystemMetricsCore"
        ),
        .executableTarget(
            name: "KillSwitch",
            dependencies: ["KeepAwakeCore", "SystemMetricsCore"],
            path: "Sources/KillSwitch"
        ),
        .executableTarget(
            name: "SystemMetricsChecks",
            dependencies: ["SystemMetricsCore"],
            path: "Tests/SystemMetricsChecks"
        )
    ]
)
