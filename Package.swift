// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KillSwitch",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "TableQueryCore",
            path: "Sources/TableQueryCore"
        ),
        .target(
            name: "DiskCleanupCore",
            dependencies: ["TableQueryCore"],
            path: "Sources/DiskCleanupCore"
        ),
        .target(
            name: "DevCleanupCore",
            dependencies: ["TableQueryCore"],
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
            dependencies: ["CSQLite", "TableQueryCore"],
            path: "Sources/SystemMetricsCore"
        ),
        .target(
            name: "ScreenTimeCore",
            path: "Sources/ScreenTimeCore"
        ),
        .target(
            name: "StartupCore",
            dependencies: ["InstallCore", "TableQueryCore"],
            path: "Sources/StartupCore"
        ),
        .executableTarget(
            name: "KillSwitch",
            dependencies: [
                "DiskCleanupCore",
                "DevCleanupCore",
                "InstallCore",
                "KeepAwakeCore",
                "ScreenTimeCore",
                "StartupCore",
                "SystemMetricsCore",
                "TableQueryCore"
            ],
            path: "Sources/KillSwitch"
        ),
        .executableTarget(
            name: "KillSwitchUpdateHelper",
            dependencies: ["InstallCore"],
            path: "Sources/KillSwitchUpdateHelper"
        ),
        .executableTarget(
            name: "DiskCleanupCoreChecks",
            dependencies: ["DiskCleanupCore", "TableQueryCore"],
            path: "Tests/DiskCleanupCoreChecks"
        ),
        .executableTarget(
            name: "DevCleanupCoreChecks",
            dependencies: ["DevCleanupCore", "TableQueryCore"],
            path: "Tests/DevCleanupCoreChecks"
        ),
        .executableTarget(
            name: "InstallCoreChecks",
            dependencies: ["InstallCore"],
            path: "Tests/InstallCoreChecks"
        ),
        .executableTarget(
            name: "SystemMetricsChecks",
            dependencies: ["InstallCore", "SystemMetricsCore", "TableQueryCore"],
            path: "Tests/SystemMetricsChecks"
        ),
        .executableTarget(
            name: "ScreenTimeCoreChecks",
            dependencies: ["ScreenTimeCore"],
            path: "Tests/ScreenTimeCoreChecks"
        ),
        .executableTarget(
            name: "StartupCoreChecks",
            dependencies: ["InstallCore", "StartupCore", "TableQueryCore"],
            path: "Tests/StartupCoreChecks"
        )
    ]
)
