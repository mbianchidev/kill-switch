import SwiftUI

private enum MainTab: Hashable {
    case resources
    case cleanup
    case watchdog
    case diagnostics
    case keepAwake
    case updates
}

struct ContentView: View {
    @State private var selectedTab: MainTab = .resources
    @StateObject private var diagnostics = DiagnosticsController.shared
    @StateObject private var watchdog = CPUWatchdog()
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            ResourcesTab()
                .tabItem { Label("Resources", systemImage: "waveform.path.ecg") }
                .tag(MainTab.resources)
            DevCleanupTab()
                .tabItem { Label("Dev cleanup", systemImage: "trash") }
                .tag(MainTab.cleanup)
            CPUWatchdogTab(monitor: watchdog)
                .tabItem { Label("Watchdog", systemImage: "exclamationmark.triangle") }
                .tag(MainTab.watchdog)
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDiagnosticsTab)) { _ in
            selectedTab = .diagnostics
        }
    }
}
