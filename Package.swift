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
        .target(
            name: "InstallCore",
            path: "Sources/InstallCore"
        ),
        .target(
            name: "SystemMetricsCore",
            path: "Sources/SystemMetricsCore"
        ),
        .executableTarget(
            name: "KillSwitch",
            dependencies: ["DevCleanupCore", "InstallCore", "KeepAwakeCore", "SystemMetricsCore"],
            path: "Sources/KillSwitch"
        ),
        .executableTarget(
            name: "DevCleanupCoreChecks",
            dependencies: ["DevCleanupCore"],
            path: "Tests/DevCleanupCoreChecks"
        ),
        .executableTarget(
            name: "InstallCoreChecks",
            dependencies: ["InstallCore"],
            path: "Tests/InstallCoreChecks"
        ),
        .executableTarget(
            name: "SystemMetricsChecks",
            dependencies: ["SystemMetricsCore"],
            path: "Tests/SystemMetricsChecks"
        )
    ]
)
