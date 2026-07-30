// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KillSwitch",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "DiskCleanupCore",
            path: "Sources/DiskCleanupCore"
        ),
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
        .target(
            name: "ScreenTimeCore",
            path: "Sources/ScreenTimeCore"
        ),
        .executableTarget(
            name: "KillSwitch",
            dependencies: [
                "DiskCleanupCore",
                "DevCleanupCore",
                "InstallCore",
                "KeepAwakeCore",
                "ScreenTimeCore",
                "SystemMetricsCore"
            ],
            path: "Sources/KillSwitch"
        ),
        .executableTarget(
            name: "DiskCleanupCoreChecks",
            dependencies: ["DiskCleanupCore"],
            path: "Tests/DiskCleanupCoreChecks"
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
        ),
        .executableTarget(
            name: "ScreenTimeCoreChecks",
            dependencies: ["ScreenTimeCore"],
            path: "Tests/ScreenTimeCoreChecks"
        )
    ]
)
