import SwiftUI
import DevCleanupCore
import SystemMetricsCore

@MainActor
struct ContentView: View {
    @State private var selectedTab: MainTab
    // Keep model lifetimes stable without observing updates across the page hierarchy.
    private let diagnostics = DiagnosticsController.shared
    @State private var watchdog = CPUWatchdog()
    private let resourceMonitor: ResourceMonitor
    @State private var diskCleanupMonitor = DiskCleanupMonitor()
    private let updater = UpdateChecker.shared
    private let startsServices: Bool
    private let systemHealth = SystemHealthMonitor.shared
    @State private var windowVisible = true
    @State private var confirmCleanup = false
    @State private var cleanupAuthorized = false
    @State private var cleanupEntryPending = false
    @State private var inspectedProcess: ActivityProcessDescriptor?

    init(
        resourceMonitor: ResourceMonitor = .shared,
        initialTab: MainTab = .dashboard,
        startsServices: Bool = true
    ) {
        self.resourceMonitor = resourceMonitor
        self.startsServices = startsServices
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationSplitView {
            AppSidebar(selection: navigationSelection)
#if KILLSWITCH_PERFORMANCE_PROBE
                .navigationSplitViewColumnWidth(min: 170, ideal: PerformanceProbeNavigation.shared.sidebarWidth, max: 245)
#else
                .navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 245)
#endif
        } detail: {
            RetainedPageHost(
                selection: selectedTab,
                content: AnyView(pageContent
                    .preferredColorScheme(.dark)
                    .environment(\.isKillSwitchWindowVisible, windowVisible)
                    .environment(\.allowsLiveOperations, startsServices)
                    .environment(\.navigatePage, { navigationSelection.wrappedValue = $0 })
                    .environment(\.inspectProcess, { inspectedProcess = $0 }))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .background(Theme.background)
        .safeAreaInset(edge: .top) { UpdateBanner(updater: updater) }
        .alert("Open Dev cleanup?", isPresented: $confirmCleanup) {
            Button("Cancel", role: .cancel) {}
            Button("Open Dev cleanup", role: .destructive) {
                cleanupAuthorized = true
                cleanupEntryPending = false
            }
        } message: {
            Text("Automatic termination is enabled. Opening this page can terminate qualifying development servers older than your saved age threshold. Age is not inactivity. Protected processes remain protected.")
        }
        .sheet(item: $inspectedProcess) { process in
            ProcessDetailSheet(process: process, resourceMonitor: resourceMonitor)
                .preferredColorScheme(.dark)
                .environment(\.isKillSwitchWindowVisible, windowVisible)
                .environment(\.allowsLiveOperations, startsServices)
                .environment(\.navigatePage, { navigationSelection.wrappedValue = $0 })
        }
        .onAppear {
            guard startsServices else { return }
            watchdog.start()
            updater.startPeriodicChecks()
            AppStartupConfirmation.contentDidAppear()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDiagnosticsTab)) { _ in
            selectedTab = .diagnostics
        }
        .onReceive(NotificationCenter.default.publisher(for: .killSwitchWindowVisibility)) { event in
            if let visible = event.object as? Bool { windowVisible = visible }
        }
#if KILLSWITCH_PERFORMANCE_PROBE
        .onReceive(PerformanceProbeNavigation.shared.$page) { page in
            if PerformanceProbeNavigation.shared.enabled { selectedTab = page }
        }
#endif
    }

    private var navigationSelection: Binding<MainTab?> {
        Binding(
            get: { selectedTab },
            set: { page in
                guard let page, page != selectedTab else { return }
                if page == .cleanup {
                    cleanupAuthorized = false
                    cleanupEntryPending = page.requiresCleanupConfirmation(
                        autoKillEnabled: DevCleanupPreferences().load().autoKillEnabled
                    )
                }
                selectedTab = page
            }
        )
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedTab {
        case .dashboard:
            ActivityDashboard(monitor: resourceMonitor, systemHealth: systemHealth, navigate: { selectedTab = $0 })
        case .resources, .memory, .disk, .network, .energy:
            if let metric = selectedTab.metric {
                ResourcesTab(monitor: resourceMonitor, initialMetric: metric)
            }
        case .system, .battery, .thermal:
            SystemHealthTab(monitor: systemHealth, resources: resourceMonitor, page: selectedTab)
        case .devServers:
            DevServersTab(resourceMonitor: resourceMonitor)
        case .connections:
            ConnectionsTab(resourceMonitor: resourceMonitor)
        case .openFiles:
            OpenFilesTab(resourceMonitor: resourceMonitor)
        case .startup:
            StartupTab()
        case .diskCleanup:
            DiskCleanupTab(monitor: diskCleanupMonitor)
        case .cleanup:
            DevCleanupTab(
                allowAutomaticTermination: $cleanupAuthorized,
                entryPending: cleanupEntryPending,
                requestConfirmation: { confirmCleanup = true },
                showDevServers: { navigationSelection.wrappedValue = .devServers }
            )
        case .watchdog:
            CPUWatchdogTab(monitor: watchdog)
        case .screenTime:
            ScreenTimeTab()
        case .diagnostics:
            DiagnosticsTab(controller: diagnostics)
        case .keepAwake:
            KeepAwakeTab()
        case .updates:
            UpdatesTab(updater: updater)
        }
    }
}
