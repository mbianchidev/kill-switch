import SwiftUI

private enum MainTab: Hashable {
    case dashboard
    case resources
    case startup
    case diskCleanup
    case cleanup
    case watchdog
    case screenTime
    case diagnostics
    case keepAwake
    case updates
}

struct ContentView: View {
    @State private var selectedTab: MainTab = .dashboard
    @StateObject private var diagnostics = DiagnosticsController.shared
    @StateObject private var watchdog = CPUWatchdog()
    @StateObject private var resourceMonitor = ResourceMonitor.shared
    @StateObject private var diskCleanupMonitor = DiskCleanupMonitor()
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            ActivityDashboard(monitor: resourceMonitor)
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }
                .tag(MainTab.dashboard)
            ResourcesTab(monitor: resourceMonitor)
                .tabItem { Label("Resources", systemImage: "waveform.path.ecg") }
                .tag(MainTab.resources)
            StartupTab()
                .tabItem { Label("Startup", systemImage: "power") }
                .tag(MainTab.startup)
            DiskCleanupTab(monitor: diskCleanupMonitor)
                .tabItem { Label("Disk cleanup", systemImage: "internaldrive") }
                .tag(MainTab.diskCleanup)
            DevCleanupTab()
                .tabItem { Label("Dev cleanup", systemImage: "trash") }
                .tag(MainTab.cleanup)
            CPUWatchdogTab(monitor: watchdog)
                .tabItem { Label("Watchdog", systemImage: "exclamationmark.triangle") }
                .tag(MainTab.watchdog)
            ScreenTimeTab()
                .tabItem { Label("Screen time", systemImage: "figure.walk.motion") }
                .tag(MainTab.screenTime)
            DiagnosticsTab(controller: diagnostics)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .tag(MainTab.diagnostics)
            KeepAwakeTab()
                .tabItem { Label("Keep awake", systemImage: "cup.and.saucer.fill") }
                .tag(MainTab.keepAwake)
            UpdatesTab(updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(MainTab.updates)
        }
        .padding(.top, 4)
        .background(Theme.background)
        .safeAreaInset(edge: .top) { UpdateBanner(updater: updater) }
        .onAppear {
            watchdog.start()
            updater.startPeriodicChecks()
            AppStartupConfirmation.contentDidAppear()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDiagnosticsTab)) { _ in
            selectedTab = .diagnostics
        }
    }

}
