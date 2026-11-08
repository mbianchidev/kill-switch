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
    @State private var cleanupMonitor: DevCleanupMonitor
    private let cleanupPreferences: DevCleanupPreferences
    private let updater = UpdateChecker.shared
    private let startsServices: Bool
    private let systemHealth = SystemHealthMonitor.shared
    @State private var windowVisible = true
    @State private var confirmCleanup = false
    @State private var cleanupAuthorized = false
    @State private var cleanupEntryPending = false
    @State private var cleanupVisitID = UUID()
    @State private var cleanupConfirmationRequest: CleanupVisitValue<Bool>?
    @State private var inspectedProcess: ActivityProcessDescriptor?

#if KILLSWITCH_PERFORMANCE_PROBE
    struct CleanupEntryProbeControls {
        let navigation: Binding<MainTab?>
        let visit: Binding<UUID>
        let authorized: Binding<Bool>
        let pending: Binding<Bool>
        let open: (UUID) -> Void
        let request: () -> CleanupVisitValue<Bool>?
        let approve: (CleanupVisitValue<Bool>) -> Void
        let cancel: (CleanupVisitValue<Bool>) -> Void
        let dismissPresentation: () -> Void
        let visibility: (Bool) -> Void
    }
    var performanceObserveCleanupEntry: ((CleanupEntryProbeControls) -> Void)?
    var performanceStartsCleanupTasks = false
#endif

    init(
        resourceMonitor: ResourceMonitor = .shared,
        initialTab: MainTab = .dashboard,
        startsServices: Bool = true,
        cleanupPreferences: DevCleanupPreferences = DevCleanupPreferences(),
        cleanupMonitor: DevCleanupMonitor? = nil
    ) {
        self.resourceMonitor = resourceMonitor
        self.startsServices = startsServices
        self.cleanupPreferences = cleanupPreferences
        _cleanupMonitor = State(initialValue: cleanupMonitor ?? DevCleanupMonitor(preferences: cleanupPreferences))
        _selectedTab = State(initialValue: initialTab)
        _cleanupEntryPending = State(initialValue: initialTab.requiresCleanupConfirmation(
            autoKillEnabled: cleanupPreferences.load().autoKillEnabled
        ))
    }

    private var cleanupPage: some View {
        let visit = cleanupVisitID
        let page = DevCleanupTab(
            allowAutomaticTermination: cleanupAuthorization(for: visit),
            visitID: $cleanupVisitID,
            entryPending: cleanupEntryPending,
            requestConfirmation: { requestCleanupEntry(visit: visit) },
            showDevServers: { navigationSelection.wrappedValue = .devServers },
            preferences: cleanupPreferences, monitor: cleanupMonitor
        )
#if KILLSWITCH_PERFORMANCE_PROBE
        var probePage = page
        probePage.performanceStartsTasks = performanceStartsCleanupTasks
        return probePage
#else
        return page
#endif
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
                    .tint(Theme.accent)
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
        .alert("Open Dev cleanup?", isPresented: Binding(
            get: { startsServices && confirmCleanup && currentCleanupConfirmation != nil },
            set: { confirmCleanup = $0 }
        ), presenting: currentCleanupConfirmation) { request in
            Button("Cancel", role: .cancel) { cancelCleanupEntry(request) }
            Button("Open Dev cleanup", role: .destructive) { authorizeCleanupEntry(request) }
        } message: { _ in
            Text("Automatic termination is enabled. Opening this page can terminate qualifying development servers older than your saved age threshold. It continues while Dev cleanup is selected, including hidden or minimized windows. Leaving the page stops future passes. Age is not inactivity. Protected processes remain protected.")
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
            navigationSelection.wrappedValue = .diagnostics
        }
        .onReceive(NotificationCenter.default.publisher(for: .killSwitchWindowVisibility)) { event in
            if let visible = event.object as? Bool {
                setWindowVisibility(visible)
            }
        }
#if KILLSWITCH_PERFORMANCE_PROBE
        .onAppear {
            performanceObserveCleanupEntry?(CleanupEntryProbeControls(
                navigation: navigationSelection, visit: $cleanupVisitID, authorized: $cleanupAuthorized,
                pending: $cleanupEntryPending, open: requestCleanupEntry,
                request: { cleanupConfirmationRequest }, approve: authorizeCleanupEntry, cancel: cancelCleanupEntry,
                dismissPresentation: { confirmCleanup = false }, visibility: setWindowVisibility
            ))
        }
        .onReceive(PerformanceProbeNavigation.shared.$page) { page in
            if PerformanceProbeNavigation.shared.enabled { navigationSelection.wrappedValue = page }
        }
#endif
    }

    private func cleanupVisitIsCurrent(_ visit: UUID) -> Bool {
        selectedTab == .cleanup && windowVisible && cleanupVisitID == visit
    }

    private var currentCleanupConfirmation: CleanupVisitValue<Bool>? {
        guard cleanupEntryPending, let request = cleanupConfirmationRequest,
              cleanupVisitIsCurrent(request.visit) else { return nil }
        return request
    }

    private func cleanupAuthorization(for visit: UUID) -> Binding<Bool> {
        Binding(
            get: { cleanupAuthorized && selectedTab == .cleanup && cleanupVisitID == visit },
            set: { authorized in
                guard cleanupVisitIsCurrent(visit) else {
                    fputs("KillSwitch ignored an expired cleanup permission update; authorization was unchanged.\n", stderr)
                    return
                }
                cleanupAuthorized = authorized
                cleanupMonitor.prepareForEntry(allowAutomaticTermination: authorized)
            }
        )
    }

    private func requestCleanupEntry(visit: UUID) {
        guard cleanupEntryPending, cleanupVisitIsCurrent(visit) else {
            fputs("KillSwitch canceled an expired cleanup entry request; no confirmation was opened.\n", stderr)
            return
        }
        cleanupConfirmationRequest = CleanupVisitValue(visit: visit, value: true)
        confirmCleanup = true
    }

    private func authorizeCleanupEntry(_ request: CleanupVisitValue<Bool>) {
        guard request.value, cleanupEntryPending, cleanupVisitIsCurrent(request.visit),
              cleanupConfirmationRequest?.id == request.id else {
            fputs("KillSwitch canceled an expired cleanup entry confirmation; automatic termination was not authorized.\n", stderr)
            return
        }
        cleanupConfirmationRequest = nil
        confirmCleanup = false
        cleanupAuthorized = true
        cleanupMonitor.start(allowAutomaticTermination: true)
        cleanupEntryPending = false
    }

    private func cancelCleanupEntry(_ request: CleanupVisitValue<Bool>) {
        guard cleanupConfirmationRequest?.id == request.id else { return }
        cleanupConfirmationRequest = nil
        confirmCleanup = false
    }

    private func setWindowVisibility(_ visible: Bool) {
        windowVisible = visible
        if cleanupAuthorized && !cleanupMonitor.cleanupConfiguration().autoKillEnabled {
            cleanupAuthorized = false
            cleanupEntryPending = selectedTab.requiresCleanupConfirmation(
                autoKillEnabled: cleanupPreferences.load().autoKillEnabled
            )
        }
        cleanupMonitor.setWindowVisible(visible)
        if !visible {
            // Suspend stale UI callbacks without revoking the selected page's confirmed execution.
            cleanupVisitID = UUID()
            if selectedTab != .cleanup || !cleanupAuthorized {
                cleanupMonitor.stop()
                cleanupAuthorized = false
                cleanupEntryPending = selectedTab.requiresCleanupConfirmation(
                    autoKillEnabled: cleanupPreferences.load().autoKillEnabled
                )
            }
            confirmCleanup = false
            cleanupConfirmationRequest = nil
        }
    }

    private var navigationSelection: Binding<MainTab?> {
        Binding(
            get: { selectedTab },
            set: { page in
                guard let page, page != selectedTab else { return }
                if selectedTab == .cleanup || page == .cleanup {
                    cleanupMonitor.stop()
                    cleanupVisitID = UUID()
                    confirmCleanup = false
                    cleanupConfirmationRequest = nil
                    cleanupAuthorized = false
                }
                if page == .cleanup {
                    cleanupEntryPending = page.requiresCleanupConfirmation(
                        autoKillEnabled: cleanupPreferences.load().autoKillEnabled
                    )
                } else {
                    cleanupEntryPending = false
                }
                selectedTab = page
            }
        )
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedTab {
        case .dashboard:
            ActivityDashboard(monitor: resourceMonitor, systemHealth: systemHealth, navigate: { navigationSelection.wrappedValue = $0 })
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
            cleanupPage
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
