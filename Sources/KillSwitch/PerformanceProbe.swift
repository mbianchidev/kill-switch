#if KILLSWITCH_PERFORMANCE_PROBE
import AppKit
import Darwin
import Foundation
import SwiftUI
import SystemMetricsCore
import DevCleanupCore
import os

@MainActor
final class PerformanceProbeNavigation: ObservableObject {
    static let shared = PerformanceProbeNavigation()
    @Published var page: MainTab = .dashboard
    var enabled = false
    var sidebarWidth: CGFloat = 195
}

// This entry point is compiled only into the separately built, non-interactive probe.
@MainActor
enum PerformanceProbe {
    static let executableIdentity = "KILLSWITCH_SYNTHETIC_PERFORMANCE_PROBE_PROTOCOL_1"

    static func run(arguments: [String]) -> Int32 {
        if arguments == ["--probe-identity"] { print(executableIdentity); return 0 }
        if arguments == ["--interface-checks"] { return interfaceChecks() }
        if arguments == ["--native-health-check"] {
            do {
                let hardware = try SystemHealthReader.hardware()
                let snapshot = SystemHealthReader.sample()
                guard !hardware.model.isEmpty, !hardware.cpuName.isEmpty,
                      hardware.logicalCPUCount > 0, hardware.physicalCPUCount > 0,
                      hardware.physicalMemoryBytes > 0, snapshot.warnings.isEmpty else {
                    fputs("Native health counters are incomplete: \(snapshot.warnings.joined(separator: "; "))\n", stderr)
                    return 1
                }
                print("Native public health counters are available; no identifying hardware fields were requested.")
                return 0
            } catch {
                fputs("Native health check failed: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        guard (3...5).contains(arguments.count),
              ["background", "dashboard", "cpu", "memory", "energy", "system", "battery", "thermal",
               "connections", "files", "servers", "inspector", "navigation", "cleanup-settings"].contains(arguments[0]),
              let duration = Double(arguments[1]), (3...600).contains(duration),
              let count = Int(arguments[2]), (1...5_000).contains(count) else {
            fputs("Usage: KillSwitch --performance-probe SCENARIO SECONDS(3...600) PROCESSES(1...5000) [OFFSCREEN.png [WIDTHxHEIGHT]]; or --performance-probe --interface-checks\n", stderr)
            return 2
        }
        let scenario = arguments[0]
        var width = 1_280
        var height = 900
        if arguments.count == 5 {
            let dimensions = arguments[4].split(separator: "x")
            guard dimensions.count == 2, let parsedWidth = Int(dimensions[0]), let parsedHeight = Int(dimensions[1]),
                  (900...1_800).contains(parsedWidth), (650...1_400).contains(parsedHeight) else {
                fputs("The offscreen size must be WIDTHxHEIGHT, between 900x650 and 1800x1400.\n", stderr)
                return 2
            }
            width = parsedWidth
            height = parsedHeight
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let cleanupSuite = "KillSwitch.synthetic-footprint-\(UUID().uuidString)"
        guard let cleanupDefaults = UserDefaults(suiteName: cleanupSuite) else {
            fputs("Performance probe could not create isolated cleanup preferences.\n", stderr)
            return 1
        }
        defer { cleanupDefaults.removePersistentDomain(forName: cleanupSuite) }
        let cleanupPreferences = DevCleanupPreferences(defaults: cleanupDefaults)
        cleanupPreferences.resetToDefaults()
        let monitor = ResourceMonitor()
        monitor.showAllUsers = true
        SystemHealthMonitor.shared.publishPerformanceFixture()
        PerformanceProbeNavigation.shared.enabled = scenario == "navigation"
        PerformanceProbeNavigation.shared.sidebarWidth = width == 900 ? 245 : 195
        let now = Date()
        for index in 0..<51 {
            monitor.publishPerformanceSample(fixture(
                date: now.addingTimeInterval(Double(index - 50) * 6), count: count, step: index
            ))
        }
        let view: NSHostingView<AnyView>?
        let window: NSWindow?
        var cleanupPreviewMonitor: DevCleanupMonitor?
        defer { cleanupPreviewMonitor?.stop() }
        if scenario == "background" {
            view = nil
            window = nil
        } else {
            let root: AnyView
            if scenario == "dashboard" || scenario == "navigation" {
                root = AnyView(ContentView(
                    resourceMonitor: monitor, startsServices: false, cleanupPreferences: cleanupPreferences
                ))
            } else if ["cpu", "memory", "energy"].contains(scenario) {
                let metric: ResourceMetric = scenario == "memory" ? .memory : scenario == "energy" ? .energy : .cpu
                root = AnyView(ResourcesTab(monitor: monitor, initialMetric: metric))
            } else if scenario == "inspector", let process = monitor.liveActivity?.processes.first?.process {
                root = AnyView(ProcessDetailSheet(process: process, resourceMonitor: monitor))
            } else if scenario == "cleanup-settings" {
                let service = DevCleanupService(
                    username: "synthetic-owner",
                    processProvider: { [
                        DevCleanupProcess(pid: 100_101, user: "synthetic-owner", elapsedSeconds: 14_400,
                                          command: "/synthetic/node /synthetic/project/node_modules/vite/bin/vite.js"),
                        DevCleanupProcess(pid: 100_102, user: "synthetic-owner", elapsedSeconds: 86_400,
                                          command: "/synthetic/python /synthetic/project/manage.py runserver")
                    ] },
                    listeningPortsProvider: { [100_101: [5_173], 100_102: [8_000]] },
                    terminator: { _ in true }
                )
                let cleanup = DevCleanupMonitor(preferences: cleanupPreferences, service: service)
                cleanupPreviewMonitor = cleanup
                var cleanupRoot = ContentView(
                    resourceMonitor: monitor, initialTab: .cleanup, startsServices: false,
                    cleanupPreferences: cleanupPreferences, cleanupMonitor: cleanup
                )
                cleanupRoot.performanceStartsCleanupTasks = true
                cleanupRoot.performanceObserveCleanupEntry = { controls in
                    guard controls.pending.wrappedValue else { return }
                    controls.open(controls.visit.wrappedValue)
                    if let request = controls.request() { controls.approve(request) }
                }
                root = AnyView(cleanupRoot)
            } else {
                let page: MainTab
                switch scenario {
                case "system": page = .system
                case "battery": page = .battery
                case "thermal": page = .thermal
                case "connections": page = .connections
                case "files": page = .openFiles
                case "servers": page = .devServers
                default:
                    fputs("The probe scenario could not be represented.\n", stderr)
                    return 2
                }
                root = AnyView(ContentView(
                    resourceMonitor: monitor, initialTab: page, startsServices: false, cleanupPreferences: cleanupPreferences
                ))
            }
            let hosting = NSHostingView(rootView: AnyView(root.preferredColorScheme(.dark).environment(\.allowsLiveOperations, false)))
            hosting.setFrameSize(NSSize(width: CGFloat(width), height: CGFloat(height)))
            let offscreen = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            offscreen.isReleasedWhenClosed = false
            offscreen.contentView = hosting
            view = hosting
            window = offscreen
        }
        defer {
            window?.contentView = nil
            window?.close()
        }
        let start = ContinuousClock.now
        let deadline = start.advanced(by: .seconds(duration))
        var nextSample = start
        var step = 51
        while ContinuousClock.now < deadline {
            if ContinuousClock.now >= nextSample {
                if scenario == "navigation" {
                    let pages: [MainTab] = [.dashboard, .resources, .memory, .energy, .connections, .openFiles,
                                            .devServers, .system, .battery, .thermal]
                    PerformanceProbeNavigation.shared.page = pages[(step - 51) % pages.count]
                }
                monitor.publishPerformanceSample(fixture(date: Date(), count: count, step: step))
                step += 1
                if let view {
                    let rendered = autoreleasepool {
                        view.layoutSubtreeIfNeeded()
                        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        return true
                    }
                    guard rendered else {
                        fputs("Performance probe could not create its offscreen rendering surface.\n", stderr)
                        return 1
                    }
                }
                nextSample = nextSample.advanced(by: .seconds(6))
            }
            autoreleasepool {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        if scenario == "cleanup-settings" {
            guard let cleanup = cleanupPreviewMonitor, cleanup.cleanupConfiguration().autoKillEnabled,
                  cleanup.performanceCleanupTimer != nil else {
                fputs("The synthetic cleanup settings did not reach the confirmed mock-only state.\n", stderr)
                return 1
            }
        }
        if arguments.count >= 4, let view {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fputs("Performance probe could not create its final offscreen image.\n", stderr)
                return 1
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                fputs("Performance probe could not encode its offscreen image.\n", stderr)
                return 1
            }
            do { try data.write(to: URL(fileURLWithPath: arguments[3]), options: .atomic) }
            catch {
                fputs("Performance image failed: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        return 0
    }

    private static func interfaceChecks() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        let pages = MainTab.sections.flatMap(\.pages)
        check(pages.count == Set(pages).count && Set(pages) == Set(MainTab.allCases), "Every page must occur exactly once in navigation.")
        for page in MainTab.allCases {
            check(page.requiresCleanupConfirmation(autoKillEnabled: true) == (page == .cleanup), "Only automatic Dev cleanup needs an entry confirmation.")
            check(!page.requiresCleanupConfirmation(autoKillEnabled: false), "Read-only cleanup entry must not request an automatic-termination confirmation.")
        }
        let monitor = ResourceMonitor()
        let first = UUID()
        let second = UUID()
        monitor.setMetric(.cpu, owner: first)
        monitor.setMetric(.energy, owner: second)
        monitor.setMetric(nil, owner: first)
        check(monitor.performanceEffectiveMetric == .energy, "An outgoing page must not clear a newer sampling lease.")
        monitor.setWindowVisible(false)
        check(monitor.performanceEffectiveMetric == nil, "Hidden windows must not request heavy metric collection.")
        monitor.setWindowVisible(true)
        check(monitor.performanceEffectiveMetric == .energy, "Showing the window must restore the selected metric.")
        monitor.setMetric(nil, owner: second)
        check(monitor.performanceEffectiveMetric == nil, "The active page must release its sampling lease.")
        queuedMetricVisibilityChecks(check)
        energyPhaseAdmissionChecks(check)
        let energyDate = Date()
        for index in 0..<61 {
            monitor.publishPerformanceSample(fixture(
                date: energyDate.addingTimeInterval(Double(index - 60) * 6), count: 1_000, step: index
            ))
        }
        check(monitor.history[.energy]?.count == 51, "Energy probes must populate and prune the full five-minute chart.")
        check(monitor.history[.energy]?.last?.primary == 2_000, "Energy chart fixtures must contain measured power totals.")
        healthPollingChecks(check)
        thermalPresentationChecks(check)
        healthObservationChecks(check)
        processDetailObservationChecks(check)
        queuedInspectionChecks(check)
        projectCacheTimingChecks(check)
        filteredProjectWarningChecks(check)
        copyFeedbackChecks(check)
        dashboardSelectionChecks(check)

        let suite = "KillSwitch.synthetic-entry-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fputs("Cannot create isolated cleanup-entry preferences.\n", stderr)
            return 1
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DevCleanupPreferences(defaults: defaults)
        preferences.setAutoKillEnabled(true)
        let cleanup = DevCleanupMonitor(preferences: preferences)
        preferences.setAutoKillEnabled(false)
        cleanup.prepareForEntry(allowAutomaticTermination: false)
        check(!cleanup.autoKillEnabled && !cleanup.cleanupConfiguration().autoKillEnabled,
              "A retained monitor must not restore stale automatic termination.")
        preferences.setAutoKillEnabled(true)
        cleanup.prepareForEntry(allowAutomaticTermination: false)
        check(!cleanup.autoKillEnabled && preferences.load().autoKillEnabled,
              "Read-only entry must remain unauthorized without overwriting saved settings.")
        cleanup.prepareForEntry(allowAutomaticTermination: true)
        check(cleanup.cleanupConfiguration().autoKillEnabled, "Explicitly authorized entry may use current saved settings.")
        preferences.setAutoKillEnabled(false)
        check(!cleanup.cleanupConfiguration().autoKillEnabled, "Later saved disablement must block the ensuing cleanup.")
        cleanupStateChecks(preferences: preferences, check)
        queuedCleanupChecks(preferences: preferences, check)
        resetAuthorizationChecks(preferences: preferences, check)
        cleanupEntryCancellationChecks(preferences: preferences, check)
        backgroundCleanupChecks(preferences: preferences, check)
        cleanupAuthorizationRevisionChecks(preferences: preferences, check)
        foregroundScanGenerationChecks(preferences: preferences, check)
        cleanupDialogCancellationChecks(preferences: preferences, check)
        queuedScanSettingsChecks(preferences: preferences, check)
        cleanupVisitResumptionChecks(preferences: preferences, check)
        let firstVisit = UUID()
        let nextVisit = UUID()
        let copiedVisit = CleanupVisitValue(visit: firstVisit, value: Int32(100_995))
        let pendingVisit = CleanupVisitValue(visit: firstVisit, value: "synthetic reset confirmation")
        check(copiedVisit.value(for: firstVisit) == 100_995 && pendingVisit.value(for: firstVisit) != nil,
              "Current-visit transient state must remain available.")
        check(copiedVisit.value(for: nextVisit) == nil && pendingVisit.value(for: nextVisit) == nil,
              "Later cleanup visits must not inherit stale copy feedback or authorization requests.")

        let controller = RetainedPageController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        var tokens: [MainTab: UUID] = [:]
        var activePages: Set<MainTab> = []
        func show(_ page: MainTab) {
            controller.show(page, content: AnyView(ProbeStateView(
                record: { tokens[page] = $0 },
                activation: { active in
                    if active { activePages.insert(page) } else { activePages.remove(page) }
                }
            )))
            controller.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        show(.dashboard)
        let token = tokens[.dashboard]
        check(controller.performancePageCount == 1, "Unvisited pages must not be constructed.")
        check(activePages == [.dashboard], "Only the selected page may receive appearance.")
        show(.resources)
        check(activePages == [.resources], "An outgoing page must receive disappearance before the next collector activates.")
        show(.dashboard)
        check(controller.performancePageCount == 2, "Returning to a visited page must reuse its controller.")
        check(token != nil && tokens[.dashboard] == token, "Returning to a visited page must preserve its SwiftUI state.")
        check(activePages == [.dashboard], "Returning to a page must deactivate its predecessor.")
        if failures.isEmpty {
            print("Interface checks passed: navigation, cleanup entry, health polling, metric leases, visibility, lazy pages, and retained state.")
            return 0
        }
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        return 1
    }

    private static func healthPollingChecks(_ check: (Bool, String) -> Void) {
        let fixtures = SystemHealthMonitor()
        fixtures.publishPerformanceFixture()
        guard let hardware = fixtures.hardware, let snapshot = fixtures.snapshot else {
            check(false, "Synthetic health fixtures must be available.")
            return
        }
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let hardwareReads = OSAllocatedUnfairLock(initialState: 0)
        var sampleNow = ContinuousClock.now
        let health = SystemHealthMonitor(
            now: { sampleNow },
            readHardware: {
                hardwareReads.withLock { $0 += 1 }
                return hardware
            },
            readSnapshot: {
                reads.withLock { $0 += 1 }
                return snapshot
            }
        )
        defer { health.shutdown() }
        func finishRead(_ monitor: SystemHealthMonitor) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            let deadline = Date().addingTimeInterval(2)
            while monitor.isRefreshing && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            check(!monitor.isRefreshing, "Synthetic health reads must finish.")
        }
        let client = UUID()
        let otherClient = UUID()
        health.setActive(true, client: client)
        finishRead(health)
        check(reads.withLock { $0 } == 1, "The first visible health client must receive an immediate sample.")
        for _ in 0..<4 {
            health.setActive(false, client: client)
            health.setActive(true, client: client)
            finishRead(health)
        }
        check(reads.withLock { $0 } == 1, "Repeated health-page navigation must not bypass the thirty-second polling limit.")
        sampleNow = sampleNow.advanced(by: .seconds(29))
        health.performanceFireAutomaticRefresh()
        finishRead(health)
        check(reads.withLock { $0 } == 1 && health.performanceHasScheduledRefresh,
              "An early timer wake must preserve the remaining cooldown without sampling.")
        sampleNow = sampleNow.advanced(by: .milliseconds(999))
        health.setActive(false, client: client)
        health.setActive(true, client: client)
        check(reads.withLock { $0 } == 1, "Health must not sample just before the thirty-second boundary.")
        sampleNow = sampleNow.advanced(by: .milliseconds(1))
        health.performanceFireAutomaticRefresh()
        finishRead(health)
        check(reads.withLock { $0 } == 2, "Automatic health polling must resume at its original deadline.")
        health.refresh()
        finishRead(health)
        check(reads.withLock { $0 } == 3, "Explicit user refresh must remain available within the automatic cooldown.")
        health.setActive(true, client: otherClient)
        health.setActive(false, client: client)
        finishRead(health)
        check(reads.withLock { $0 } == 3, "Overlapping visible clients must share the same poll budget.")
        health.setActive(false, client: otherClient)
        check(!health.performanceHasScheduledRefresh, "Hidden health pages must cancel their scheduled poll.")
        sampleNow = sampleNow.advanced(by: .seconds(600))
        health.refresh()
        finishRead(health)
        check(reads.withLock { $0 } == 3, "Hidden health pages must not perform any new read.")
        health.setActive(true, client: client)
        finishRead(health)
        check(reads.withLock { $0 } == 4, "A stale health cache must refresh immediately on returning.")
        check(hardwareReads.withLock { $0 } == 1, "Successful hardware information must only be read once.")

        let blockedReads = OSAllocatedUnfairLock(initialState: 0)
        let blockedHardwareReads = OSAllocatedUnfairLock(initialState: 0)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let started = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let blockedHealth = SystemHealthMonitor(
            now: { sampleNow },
            readHardware: {
                blockedHardwareReads.withLock { $0 += 1 }
                return hardware
            },
            readSnapshot: {
                blockedReads.withLock { $0 += 1 }
                started.signal()
                if released.wait(timeout: .now() + 5) != .success {
                    timedOut.withLock { $0 = true }
                }
                return snapshot
            }
        )
        defer { blockedHealth.shutdown() }
        blockedHealth.setActive(true, client: client)
        check(started.wait(timeout: .now() + 2) == .success, "The controlled in-flight health read must start.")
        blockedHealth.setActive(false, client: client)
        blockedHealth.setActive(true, client: otherClient)
        released.signal()
        finishRead(blockedHealth)
        check(blockedReads.withLock { $0 } == 1 && blockedHealth.snapshot == snapshot && blockedHealth.hardware == hardware,
              "A completing shared health read must remain available across page handoff without another poll.")
        blockedHealth.refresh()
        check(started.wait(timeout: .now() + 2) == .success, "An explicit in-flight refresh must start.")
        blockedHealth.setActive(false, client: otherClient)
        released.signal()
        finishRead(blockedHealth)
        check(!blockedHealth.performanceHasScheduledRefresh, "Completing a read while hidden must not schedule another poll.")
        blockedHealth.setActive(true, client: client)
        finishRead(blockedHealth)
        check(blockedReads.withLock { $0 } == 2 && blockedHardwareReads.withLock { $0 } == 1,
              "Re-entry must use the completed shared cache without rereading hardware or bypassing cooldown.")
        let queuedReads = OSAllocatedUnfairLock(initialState: 0)
        let queueReleased = DispatchSemaphore(value: 0)
        let queuedHealth = SystemHealthMonitor(
            now: { sampleNow },
            readHardware: {
                queuedReads.withLock { $0 += 1 }
                return hardware
            },
            readSnapshot: {
                queuedReads.withLock { $0 += 1 }
                return snapshot
            }
        )
        defer { queuedHealth.shutdown() }
        queuedHealth.performanceEnqueue {
            if queueReleased.wait(timeout: .now() + 5) != .success {
                timedOut.withLock { $0 = true }
            }
        }
        queuedHealth.setActive(true, client: client)
        queuedHealth.setActive(false, client: client)
        queueReleased.signal()
        finishRead(queuedHealth)
        check(queuedReads.withLock { $0 } == 0 && !queuedHealth.performanceHasScheduledRefresh,
              "A queued health refresh must not begin reading after its last visible client disappears.")
        queuedHealth.setActive(true, client: client)
        finishRead(queuedHealth)
        check(queuedReads.withLock { $0 } == 2 && queuedHealth.snapshot == snapshot,
              "A canceled queued health read must not delay the next visible client's first sample.")
        let windowReads = OSAllocatedUnfairLock(initialState: 0)
        let windowReleased = DispatchSemaphore(value: 0)
        let windowHealth = SystemHealthMonitor(
            readHardware: { windowReads.withLock { $0 += 1 }; return hardware },
            readSnapshot: { windowReads.withLock { $0 += 1 }; return snapshot }
        )
        defer { windowHealth.shutdown() }
        windowHealth.performanceEnqueue {
            if windowReleased.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
        }
        windowHealth.setActive(true, client: client)
        windowHealth.setWindowVisible(false)
        windowReleased.signal()
        finishRead(windowHealth)
        check(windowReads.withLock { $0 } == 0 && !windowHealth.performanceHasScheduledRefresh,
              "Application visibility must block queued health reads before SwiftUI removes their visible clients.")
        windowHealth.setWindowVisible(true)
        finishRead(windowHealth)
        check(windowReads.withLock { $0 } == 2 && windowHealth.snapshot == snapshot,
              "Showing the window must resume a canceled health read without depending on a view callback.")
        windowHealth.setWindowVisible(false)
        windowHealth.setWindowVisible(true)
        finishRead(windowHealth)
        check(windowReads.withLock { $0 } == 2,
              "Direct coalesced window visibility must retain the shared health polling deadline.")
        check(!timedOut.withLock { $0 }, "Controlled synthetic health reads must not time out.")
    }

    private static func queuedInspectionChecks(_ check: (Bool, String) -> Void) {
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let released = DispatchSemaphore(value: 0)
        let inspection = ProcessInspectionMonitor()
        defer { inspection.stop() }
        inspection.performanceEnqueue {
            if released.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
        }
        inspection.start(.files)
        inspection.refresh()
        inspection.stop()
        check(inspection.files.isEmpty && inspection.connections.isEmpty && inspection.identities.isEmpty
              && inspection.projects.isEmpty && inspection.lastUpdated == nil,
              "Hiding inspection must release its visible snapshot immediately, without waiting for the collector queue.")
        released.signal()
        check(inspection.performanceSampleModes.isEmpty, "A queued inspection refresh must be canceled before collecting after hiding.")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(!inspection.isRefreshing && inspection.files.isEmpty && inspection.connections.isEmpty,
              "Canceled inspection work must not restore a hidden snapshot or leave a busy state.")

        let reactivated = ProcessInspectionMonitor()
        let reactivationReleased = DispatchSemaphore(value: 0)
        defer { reactivated.stop() }
        reactivated.performanceEnqueue {
            if reactivationReleased.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
        }
        reactivated.start(.files)
        let warning = "Synthetic files inspection permission warning."
        reactivated.performanceReportError(warning)
        let status = InspectionStatus(monitor: reactivated, count: 0, noun: "files")
        check(reactivated.errorMessage == warning && !reactivated.errorIsFromPreviousActivation
              && status.issueLabel == "Inspection reported a warning or error",
              "A current inspection issue must retain its detail and current warning label.")
        reactivated.refresh()
        reactivated.stop()
        check(reactivated.errorMessage == warning && reactivated.errorIsFromPreviousActivation
              && status.issueLabel == "Previous inspection warning or error",
              "Hiding inspection must retain unresolved errors while explicitly labeling them as previous.")
        reactivated.start(.connections)
        check(reactivated.isRefreshing, "A queued inspection activation must immediately show its pending refresh.")
        check(reactivated.errorMessage == warning && reactivated.errorIsFromPreviousActivation
              && status.issueLabel == "Previous inspection warning or error",
              "An old inspection error must not become a current failure during re-entry or mode handoff.")
        let currentError = "Synthetic connection inspection failed."
        reactivated.performanceReportError(currentError)
        check(reactivated.errorMessage == currentError && !reactivated.errorIsFromPreviousActivation
              && status.issueLabel == "Inspection reported a warning or error",
              "A failed retry must replace the previous warning with the current activation's error.")
        reactivated.refresh()
        reactivationReleased.signal()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && (reactivated.connections.isEmpty || reactivated.isRefreshing) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let modes = reactivated.performanceSampleModes
        check(!modes.isEmpty && modes.allSatisfy { $0 == .connections },
              "A new inspection activation must collect only its current mode, not queued work from its predecessor.")
        check(reactivated.lastUpdated != nil && reactivated.errorMessage == nil
              && !reactivated.errorIsFromPreviousActivation && !reactivated.isRefreshing,
              "A successful current inspection must clear both its unresolved issue and previous-activation state.")
        let previousVisibility = AppWindowVisibility.isVisible
        defer { AppWindowVisibility.setVisible(previousVisibility) }
        let windowInspection = ProcessInspectionMonitor()
        defer { windowInspection.stop() }
        let windowReleased = DispatchSemaphore(value: 0)
        windowInspection.performanceEnqueue {
            if windowReleased.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
        }
        windowInspection.start(.files)
        AppWindowVisibility.setVisible(false)
        windowReleased.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(windowInspection.performanceSampleModes.isEmpty,
              "Application visibility must block queued inspection before SwiftUI stops its activation.")
        windowInspection.stop()
        AppWindowVisibility.setVisible(true)
        windowInspection.start(.connections)
        let windowReadDeadline = Date().addingTimeInterval(2)
        while windowInspection.performanceSampleModes.isEmpty && Date() < windowReadDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check(windowInspection.performanceSampleModes == [.connections],
              "A shown inspection window must collect only its current resumed activation.")
        check(!timedOut.withLock { $0 }, "Controlled synthetic inspection queues must not time out.")
    }

    private static func projectCacheTimingChecks(_ check: (Bool, String) -> Void) {
        let previousVisibility = AppWindowVisibility.isVisible
        AppWindowVisibility.setVisible(true)
        defer { AppWindowVisibility.setVisible(previousVisibility) }
        let inspection = ProcessInspectionMonitor()
        defer { inspection.stop() }
        let origin = ContinuousClock.now
        let wallDate = Date(timeIntervalSince1970: 1_000_000)
        func finishRead() {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while inspection.isRefreshing && ContinuousClock.now < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            check(!inspection.isRefreshing, "Synthetic project-cache reads must finish.")
        }
        inspection.performanceSetProjectTime(origin, date: wallDate)
        inspection.start(.listeners)
        finishRead()
        let reads = inspection.performanceProjectReadCount
        check(reads > 0 && reads == inspection.identities.count && inspection.lastUpdated == wallDate,
              "A fresh listener inventory must collect each synthetic project and retain its wall-clock display date.")
        inspection.performanceSetProjectTime(origin.advanced(by: .milliseconds(29_999)),
                                             date: wallDate.addingTimeInterval(29.999))
        inspection.refresh()
        finishRead()
        check(inspection.performanceProjectReadCount == reads, "Project context remains cached just before thirty seconds.")

        let earlierDate = wallDate.addingTimeInterval(-3_600)
        inspection.performanceSetProjectTime(origin.advanced(by: .seconds(30)), date: earlierDate)
        inspection.refresh()
        finishRead()
        check(inspection.performanceProjectReadCount == reads * 2 && inspection.lastUpdated == earlierDate,
              "Project context expires at thirty monotonic seconds even when the displayed wall clock moves backward.")
        let laterDate = wallDate.addingTimeInterval(86_400)
        inspection.performanceSetProjectTime(origin.advanced(by: .milliseconds(59_999)), date: laterDate)
        inspection.refresh()
        finishRead()
        check(inspection.performanceProjectReadCount == reads * 2 && inspection.lastUpdated == laterDate,
              "A forward wall-clock jump must not force early project metadata reads.")
        inspection.performanceSetProjectTime(origin.advanced(by: .seconds(60)), date: laterDate)
        inspection.refresh()
        finishRead()
        check(inspection.performanceProjectReadCount == reads * 3,
              "The next project-cache deadline must expire without requiring the wall clock to advance.")
    }

    private static func cleanupStateChecks(preferences: DevCleanupPreferences, _ check: (Bool, String) -> Void) {
        let controller = RetainedPageController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        var currentMonitor: DevCleanupMonitor?
        var portSearch: Binding<String>?
        var cleanedSearch: Binding<String>?
        let visitID = UUID()
        func showCleanup(entryPending: Bool) {
            var page = DevCleanupTab(
                allowAutomaticTermination: .constant(false), visitID: .constant(visitID), entryPending: entryPending,
                requestConfirmation: {}, showDevServers: {}, preferences: preferences
            )
            page.performanceObserveState = {
                currentMonitor = $0
                portSearch = $1
                cleanedSearch = $2
            }
            controller.show(.cleanup, content: AnyView(page.environment(\.allowsLiveOperations, false)))
            controller.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        showCleanup(entryPending: false)
        guard let originalMonitor = currentMonitor, let originalPortSearch = portSearch,
              let originalCleanedSearch = cleanedSearch else {
            check(false, "The isolated cleanup page must expose its retained state.")
            return
        }
        originalMonitor.candidateCount = 3
        originalMonitor.cleaned = [CleanedProcess(
            pid: 100_991, command: "/synthetic/node /synthetic/vite.js", runtime: "node", ageHours: 36
        )]
        originalPortSearch.wrappedValue = "synthetic port filter"
        originalCleanedSearch.wrappedValue = "synthetic cleanup filter"
        showCleanup(entryPending: true)
        showCleanup(entryPending: false)
        check(currentMonitor === originalMonitor && currentMonitor?.candidateCount == 3 && currentMonitor?.cleaned.count == 1,
              "The safe cleanup preview must retain its monitor and prior session results.")
        check(portSearch?.wrappedValue == "synthetic port filter" && cleanedSearch?.wrappedValue == "synthetic cleanup filter",
              "Cleanup search state must survive its safe preview and confirmation transition.")
        check(currentMonitor?.lastRun == nil, "The isolated cleanup-state check must never start a live cleanup pass.")
    }

    private static func queuedCleanupChecks(preferences: DevCleanupPreferences, _ check: (Bool, String) -> Void) {
        let savedAutoKill = preferences.load().autoKillEnabled
        defer { preferences.setAutoKillEnabled(savedAutoKill) }
        preferences.setAutoKillEnabled(true)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let terminated = OSAllocatedUnfairLock(initialState: [Int32]())
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let service = DevCleanupService(
            username: "synthetic-owner",
            processProvider: {
                reads.withLock { $0 += 1 }
                return [DevCleanupProcess(
                    pid: 100_999, user: "synthetic-owner", elapsedSeconds: 1_000_000,
                    command: "/synthetic/node /synthetic/vite/bin/vite.js"
                )]
            },
            listeningPortsProvider: { [100_999: [3_000]] },
            terminator: { pid in terminated.withLock { $0.append(pid) }; return true }
        )
        let released = DispatchSemaphore(value: 0)
        let monitor = DevCleanupMonitor(preferences: preferences, service: service)
        defer { monitor.stop() }
        monitor.performanceEnqueue {
            if released.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
        }
        monitor.start(allowAutomaticTermination: true)
        monitor.refreshPorts()
        monitor.stop()
        released.signal()
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(reads.withLock { $0 } == 0 && terminated.withLock { $0.isEmpty },
              "Stopping cleanup must cancel queued scans and cleanup before any provider or terminator runs.")
        check(monitor.lastRun == nil && monitor.portProcesses.isEmpty && monitor.cleaned.isEmpty,
              "Canceled cleanup work must not publish a later result into the safe preview.")
        reads.withLock { $0 = 0 }
        terminated.withLock { $0 = [] }
        preferences.setAutoKillEnabled(true)
        let laterReleased = DispatchSemaphore(value: 0)
        let laterMonitor = DevCleanupMonitor(preferences: preferences, service: service)
        defer { laterMonitor.stop() }
        laterMonitor.performanceEnqueue {
            if laterReleased.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
        }
        laterMonitor.start(allowAutomaticTermination: true)
        preferences.setAutoKillEnabled(false)
        laterReleased.signal()
        laterMonitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(reads.withLock { $0 } == 1 && terminated.withLock { $0.isEmpty },
              "Saved disablement after enqueueing must still prevent automatic termination when the queued pass begins.")
        laterMonitor.stop()
        preferences.setAutoKillEnabled(true)
        let inFlightStarted = DispatchSemaphore(value: 0)
        let inFlightReleased = DispatchSemaphore(value: 0)
        let inFlightService = DevCleanupService(
            username: "synthetic-owner",
            processProvider: {
                inFlightStarted.signal()
                if inFlightReleased.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
                return [DevCleanupProcess(
                    pid: 100_998, user: "synthetic-owner", elapsedSeconds: 1_000_000,
                    command: "/synthetic/node /synthetic/vite/bin/vite.js"
                )]
            },
            listeningPortsProvider: { [100_998: [3_000]] },
            terminator: { _ in true }
        )
        let inFlight = DevCleanupMonitor(preferences: preferences, service: inFlightService)
        defer { inFlight.stop() }
        inFlight.start(allowAutomaticTermination: true)
        check(inFlightStarted.wait(timeout: .now() + 2) == .success, "The injected cleanup pass must enter its provider.")
        inFlight.stop()
        inFlightReleased.signal()
        inFlight.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(inFlight.lastRun != nil && inFlight.cleaned.map(\.pid) == [100_998],
              "An already-started authorized cleanup must retain its outcome after its page disappears.")
        check(!timedOut.withLock { $0 }, "The controlled synthetic cleanup queue must not time out.")
    }

    private static func cleanupEntryCancellationChecks(preferences: DevCleanupPreferences, _ check: (Bool, String) -> Void) {
        let savedAutoKill = preferences.load().autoKillEnabled
        defer { preferences.setAutoKillEnabled(savedAutoKill) }
        preferences.setAutoKillEnabled(true)
        let terminated = OSAllocatedUnfairLock(initialState: [Int32]())
        let service = DevCleanupService(
            username: "synthetic-owner",
            processProvider: { [DevCleanupProcess(
                pid: 100_996, user: "synthetic-owner", elapsedSeconds: 1_000_000,
                command: "/synthetic/node /synthetic/vite/bin/vite.js"
            )] },
            listeningPortsProvider: { [100_996: [3_000]] },
            terminator: { pid in terminated.withLock { $0.append(pid) }; return true }
        )
        let monitor = DevCleanupMonitor(preferences: preferences, service: service)
        defer { monitor.stop() }
        var controls: ContentView.CleanupEntryProbeControls?
        var root = ContentView(
            resourceMonitor: ResourceMonitor(), startsServices: false,
            cleanupPreferences: preferences, cleanupMonitor: monitor
        )
        root.performanceObserveCleanupEntry = { controls = $0 }
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard let controls else {
            check(false, "The isolated parent must expose its real cleanup-entry handlers.")
            return
        }
        controls.navigation.wrappedValue = .cleanup
        controls.open(controls.visit.wrappedValue)
        guard let firstRequest = controls.request() else {
            check(false, "A current cleanup visit must be able to request confirmation.")
            return
        }
        controls.navigation.wrappedValue = .devServers
        controls.navigation.wrappedValue = .cleanup
        controls.approve(firstRequest)
        check(!controls.authorized.wrappedValue && controls.pending.wrappedValue,
              "A delayed confirmation from a canceled visit must not authorize a coalesced new cleanup visit.")
        monitor.start(allowAutomaticTermination: controls.authorized.wrappedValue)
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        check(terminated.withLock { $0.isEmpty }, "A canceled parent confirmation must not authorize the mock terminator.")
        monitor.stop()
        terminated.withLock { $0 = [] }

        controls.navigation.wrappedValue = .devServers
        controls.navigation.wrappedValue = .cleanup
        controls.open(controls.visit.wrappedValue)
        guard let canceledRequest = controls.request() else {
            check(false, "A subsequent cleanup preview must be able to request confirmation.")
            return
        }
        controls.cancel(canceledRequest)
        controls.approve(canceledRequest)
        check(!controls.authorized.wrappedValue && controls.pending.wrappedValue,
              "Cancel must invalidate the request even without leaving its cleanup visit.")
        controls.open(controls.visit.wrappedValue)
        guard let currentRequest = controls.request() else {
            check(false, "Cancel must preserve the ability to explicitly retry confirmation.")
            return
        }
        controls.approve(canceledRequest)
        check(!controls.authorized.wrappedValue && controls.request()?.id == currentRequest.id,
              "An old same-visit confirmation must not consume or approve a newer request.")
        controls.dismissPresentation()
        controls.approve(currentRequest)
        check(controls.authorized.wrappedValue && !controls.pending.wrappedValue && controls.request() == nil,
              "A valid presented confirmation must remain usable when the native alert first clears its presentation binding.")

        let released = DispatchSemaphore(value: 0)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        monitor.performanceDrainWorkQueue()
        controls.navigation.wrappedValue = .devServers
        controls.navigation.wrappedValue = .cleanup
        controls.open(controls.visit.wrappedValue)
        guard let hiddenRequest = controls.request() else {
            check(false, "An unconfirmed visit must expose a cancelable entry request.")
            return
        }
        terminated.withLock { $0 = [] }
        monitor.performanceEnqueue {
            if released.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
        }
        monitor.start(allowAutomaticTermination: false)
        controls.visibility(false)
        check(!controls.authorized.wrappedValue && !monitor.cleanupConfiguration().autoKillEnabled,
              "Hiding an unconfirmed visit must never grant background cleanup authorization.")
        controls.visibility(true)
        released.signal()
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        check(terminated.withLock { $0.isEmpty },
              "Hiding an unconfirmed visit must not permit the mock terminator.")
        controls.approve(hiddenRequest)
        check(!controls.authorized.wrappedValue && controls.pending.wrappedValue,
              "Showing the window must restore the safe preview instead of accepting a pre-hide confirmation.")
        controls.open(firstRequest.visit)
        check(controls.request() == nil, "A delayed preview button must not request confirmation for an expired visit.")
        check(!timedOut.withLock { $0 }, "The window-cancellation mock queue must not time out.")
    }

    private static func backgroundCleanupChecks(preferences: DevCleanupPreferences, _ check: (Bool, String) -> Void) {
        let savedAutoKill = preferences.load().autoKillEnabled
        defer { preferences.setAutoKillEnabled(savedAutoKill) }
        preferences.setAutoKillEnabled(true)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let terminations = OSAllocatedUnfairLock(initialState: 0)
        let service = DevCleanupService(
            username: "synthetic-owner",
            processProvider: {
                reads.withLock { $0 += 1 }
                return [DevCleanupProcess(pid: 100_990, user: "synthetic-owner", elapsedSeconds: 1_000_000,
                                          command: "/synthetic/node /synthetic/vite/bin/vite.js")]
            },
            listeningPortsProvider: { [100_990: [3_000]] },
            terminator: { _ in terminations.withLock { $0 += 1 }; return true }
        )
        let monitor = DevCleanupMonitor(preferences: preferences, service: service)
        defer { monitor.stop() }
        var controls: ContentView.CleanupEntryProbeControls?
        var root = ContentView(resourceMonitor: ResourceMonitor(), initialTab: .cleanup, startsServices: false,
                               cleanupPreferences: preferences, cleanupMonitor: monitor)
        root.performanceObserveCleanupEntry = { controls = $0 }
        root.performanceStartsCleanupTasks = true
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard let controls else { check(false, "Background cleanup must expose its actual parent handlers."); return }
        controls.visibility(false)
        controls.visibility(true)
        check(!controls.authorized.wrappedValue && reads.withLock({ $0 }) == 0,
              "Merely hiding and showing a cleanup preview must not start background cleanup.")
        controls.open(controls.visit.wrappedValue)
        guard let request = controls.request() else { check(false, "Background cleanup requires explicit entry confirmation."); return }
        controls.approve(request)
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        check(terminations.withLock({ $0 }) == 1,
              "Confirmed cleanup must start immediately, without depending on the next visible-content task.")
        if monitor.performanceCleanupTimer == nil { monitor.start(allowAutomaticTermination: true) }
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        let deadline = monitor.performanceCleanupTimer?.fireDate
        let initialReads = reads.withLock { $0 }
        let initialTerminations = terminations.withLock { $0 }
        let released = DispatchSemaphore(value: 0)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        monitor.performanceEnqueue {
            if released.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
        }
        monitor.refreshPorts()
        let visibleVisit = controls.visit.wrappedValue
        controls.visibility(false)
        check(controls.authorized.wrappedValue && !controls.pending.wrappedValue
              && monitor.cleanupConfiguration().autoKillEnabled,
              "Confirmed cleanup remains authorized while its selected page is hidden or minimized.")
        check(controls.visit.wrappedValue != visibleVisit,
              "Hiding must still invalidate stale UI callbacks without revoking confirmed background execution.")
        check(!monitor.performanceHasPortTimer && deadline != nil && monitor.performanceCleanupTimer?.fireDate == deadline,
              "Hiding pauses foreground port polling while preserving the existing cleanup deadline.")
        if let timer = monitor.performanceCleanupTimer {
            timer.fire()
        } else { check(false, "Selected background cleanup must retain its periodic timer.") }
        released.signal()
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        check(reads.withLock({ $0 }) == initialReads + 1 && terminations.withLock({ $0 }) == initialTerminations + 1,
              "A hidden timer must run mock cleanup while a queued foreground-only port scan is canceled.")
        controls.visibility(true)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        monitor.performanceDrainWorkQueue()
        check(monitor.performanceHasPortTimer && monitor.performanceCleanupTimer?.fireDate == deadline
              && terminations.withLock({ $0 }) == initialTerminations + 1,
              "Showing confirmed cleanup resumes port polling without restarting cleanup or resetting its cadence.")
        controls.approve(request)
        check(controls.authorized.wrappedValue && !controls.pending.wrappedValue,
              "An expired UI confirmation must not disturb an already-confirmed background session.")
        let staleTimer = monitor.performanceCleanupTimer
        controls.navigation.wrappedValue = .devServers
        staleTimer?.fire()
        monitor.performanceDrainWorkQueue()
        check(!controls.authorized.wrappedValue && monitor.performanceCleanupTimer == nil
              && terminations.withLock({ $0 }) == initialTerminations + 1,
              "Leaving Dev cleanup cancels its background session and stale timer callbacks.")
        controls.navigation.wrappedValue = .cleanup
        controls.open(controls.visit.wrappedValue)
        guard let nextRequest = controls.request() else { check(false, "Returning after page exit requires fresh confirmation."); return }
        controls.approve(nextRequest)
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        controls.visibility(false)
        monitor.autoKillEnabled = false
        check(!monitor.cleanupConfiguration().autoKillEnabled && monitor.performanceCleanupTimer == nil
              && !monitor.performanceHasPortTimer,
              "Disabling auto-kill immediately revokes permission and stops hidden cleanup timers.")
        controls.visibility(true)
        check(!controls.authorized.wrappedValue,
              "Returning after disablement must not restore the former background authorization.")
        check(!timedOut.withLock { $0 }, "Background cleanup's controlled mock queue must not time out.")
    }

    private static func cleanupAuthorizationRevisionChecks(preferences: DevCleanupPreferences, _ check: (Bool, String) -> Void) {
        let savedAutoKill = preferences.load().autoKillEnabled
        defer { preferences.setAutoKillEnabled(savedAutoKill) }
        preferences.setAutoKillEnabled(true)
        let terminations = OSAllocatedUnfairLock(initialState: 0)
        let service = DevCleanupService(
            username: "synthetic-owner",
            processProvider: { [DevCleanupProcess(pid: 100_989, user: "synthetic-owner", elapsedSeconds: 1_000_000,
                                                 command: "/synthetic/node /synthetic/vite/bin/vite.js")] },
            listeningPortsProvider: { [100_989: [3_000]] },
            terminator: { _ in terminations.withLock { $0 += 1 }; return true }
        )
        let monitor = DevCleanupMonitor(preferences: preferences, service: service)
        defer { monitor.stop() }
        monitor.start(allowAutomaticTermination: true)
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let started = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        monitor.performanceBeforeRevocation {
            started.signal()
            if released.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
        }
        preferences.setAutoKillEnabled(false)
        monitor.runCleanup()
        check(started.wait(timeout: .now() + 2) == .success, "A controlled disabled pass must reach permission revocation.")
        preferences.setAutoKillEnabled(true)
        monitor.prepareForEntry(allowAutomaticTermination: true)
        released.signal()
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        check(monitor.cleanupConfiguration().autoKillEnabled && terminations.withLock({ $0 }) == 1,
              "A stale disabled pass must not revoke newer explicitly confirmed permission or terminate from its old snapshot.")
        monitor.runCleanup()
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        check(terminations.withLock({ $0 }) == 2, "The newer confirmed permission must remain usable by its next cleanup pass.")
        check(!timedOut.withLock { $0 }, "The controlled authorization-revision queue must not time out.")
    }

    private static func foregroundScanGenerationChecks(preferences: DevCleanupPreferences, _ check: (Bool, String) -> Void) {
        let savedAutoKill = preferences.load().autoKillEnabled
        preferences.setAutoKillEnabled(true)
        defer { preferences.setAutoKillEnabled(savedAutoKill) }
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let queuedService = DevCleanupService(
            username: "synthetic-owner",
            processProvider: {
                reads.withLock { $0 += 1 }
                return [DevCleanupProcess(pid: 100_980, user: "synthetic-owner", elapsedSeconds: 1,
                                          command: "/synthetic/worker")]
            },
            listeningPortsProvider: { [100_980: [3_000]] }, terminator: { _ in false }
        )
        let queued = DevCleanupMonitor(preferences: preferences, service: queuedService)
        defer { queued.stop() }
        queued.start(allowAutomaticTermination: true)
        queued.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let initialReads = reads.withLock { $0 }
        let releaseQueue = DispatchSemaphore(value: 0)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        queued.performanceEnqueue {
            if releaseQueue.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
        }
        queued.refreshPorts()
        queued.setWindowVisible(false)
        queued.setWindowVisible(true)
        releaseQueue.signal()
        queued.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(reads.withLock({ $0 }) == initialReads + 1,
              "Coalesced hide/show must admit only the new foreground scan, not resurrect its pre-hide queued predecessor.")
        check(queued.keepsRunningInBackground, "Foreground generation invalidation must preserve confirmed background cleanup.")

        for fails in [false, true] {
            let sampleCount = OSAllocatedUnfairLock(initialState: 0)
            let oldStarted = DispatchSemaphore(value: 0)
            let releaseOld = DispatchSemaphore(value: 0)
            let freshStarted = DispatchSemaphore(value: 0)
            let releaseFresh = DispatchSemaphore(value: 0)
            let service = DevCleanupService(
                username: "synthetic-owner",
                processProvider: {
                    let sample = sampleCount.withLock { value in value += 1; return value }
                    if sample == 2 {
                        oldStarted.signal()
                        if releaseOld.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
                        if fails { throw ProcessInspectionError(message: "Synthetic stale foreground failure.") }
                    } else if sample == 3 {
                        freshStarted.signal()
                        if releaseFresh.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
                    }
                    return [DevCleanupProcess(pid: 100_981, user: "synthetic-owner", elapsedSeconds: 1,
                                              command: "/synthetic/worker-sample-\(sample)")]
                },
                listeningPortsProvider: { [100_981: [3_000]] }, terminator: { _ in false }
            )
            let monitor = DevCleanupMonitor(preferences: preferences, service: service)
            defer { releaseOld.signal(); releaseFresh.signal(); monitor.stop() }
            monitor.start(allowAutomaticTermination: true)
            monitor.performanceDrainWorkQueue()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            monitor.refreshPorts()
            check(oldStarted.wait(timeout: .now() + 2) == .success, "The controlled old foreground scan must start.")
            monitor.setWindowVisible(false)
            monitor.setWindowVisible(true)
            releaseOld.signal()
            check(freshStarted.wait(timeout: .now() + 2) == .success, "A fresh foreground scan must start on return.")
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(monitor.performanceIsRefreshing && monitor.portProcesses.first?.command == "/synthetic/worker-sample-1",
                  "An expired foreground \(fails ? "error" : "success") must not overwrite current rows or clear its successor's busy state.")
            releaseFresh.signal()
            monitor.performanceDrainWorkQueue()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(!monitor.performanceIsRefreshing && monitor.portProcesses.first?.command == "/synthetic/worker-sample-3",
                  "The current foreground generation must publish its own successful result.")
        }
        check(!timedOut.withLock { $0 }, "Controlled foreground scan generations must not time out.")
    }

    private static func cleanupDialogCancellationChecks(preferences: DevCleanupPreferences, _ check: (Bool, String) -> Void) {
        let savedAutoKill = preferences.load().autoKillEnabled
        defer { preferences.setAutoKillEnabled(savedAutoKill) }
        preferences.setAutoKillEnabled(false)
        let terminated = OSAllocatedUnfairLock(initialState: [Int32]())
        let service = DevCleanupService(
            username: "synthetic-owner",
            processProvider: { [DevCleanupProcess(
                pid: 100_994, user: "synthetic-owner", elapsedSeconds: 1_000_000,
                command: "/synthetic/node /synthetic/vite/bin/vite.js"
            )] },
            listeningPortsProvider: { [100_994: [3_000]] },
            terminator: { pid in terminated.withLock { $0.append(pid) }; return true }
        )
        let monitor = DevCleanupMonitor(preferences: preferences, service: service)
        defer { monitor.stop() }
        var authorized = false
        var controls: DevCleanupTab.AuthorizationProbeControls?
        var page = DevCleanupTab(
            allowAutomaticTermination: Binding(get: { authorized }, set: { authorized = $0 }),
            visitID: .constant(UUID()), entryPending: false, requestConfirmation: {}, showDevServers: {},
            preferences: preferences, monitor: monitor
        )
        page.performanceObserveAuthorization = { controls = $0 }
        let controller = NSHostingController(rootView: page.environment(\.allowsLiveOperations, false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard let controls else {
            check(false, "The synthetic cleanup view must expose its actual reset/enable confirmation handlers.")
            return
        }
        monitor.start(allowAutomaticTermination: false)
        monitor.performanceDrainWorkQueue()
        let firstReadDeadline = Date().addingTimeInterval(2)
        while monitor.lastRun == nil && Date() < firstReadDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check(monitor.lastRun != nil, "The synthetic cleanup dialog must finish its initial read-only pass before testing reset.")
        controls.reset()
        guard let canceledReset = controls.confirmation() else {
            check(false, "A current reset must be able to request explicit confirmation.")
            return
        }
        controls.cancel()
        canceledReset()
        check(!authorized && !preferences.load().autoKillEnabled && !monitor.cleanupConfiguration().autoKillEnabled,
              "A canceled reset confirmation must not restore settings or grant termination permission within the same visit.")
        controls.enable()
        let enableID = controls.requestID()
        canceledReset()
        check(!authorized && controls.requestID() == enableID,
              "A delayed reset callback must not approve or consume a newer enable request.")
        controls.reset()
        guard let currentReset = controls.confirmation() else {
            check(false, "Cancel must preserve the ability to request a fresh reset.")
            return
        }
        controls.dismissPresentation()
        currentReset()
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        check(authorized && preferences.load().autoKillEnabled && monitor.cleanupConfiguration().autoKillEnabled
              && controls.requestID() == nil,
              "A current reset must remain valid after native presentation dismissal and consume its own request.")
        let originalTerminationCount = terminated.withLock { $0.count }
        check(originalTerminationCount == 1, "A freshly confirmed reset must still permit the single synthetic eligible termination.")
        currentReset()
        monitor.performanceDrainWorkQueue()
        check(terminated.withLock { $0.count } == originalTerminationCount,
              "Replaying a consumed reset must not enqueue an additional mock termination.")
    }

    private static func queuedScanSettingsChecks(preferences: DevCleanupPreferences, _ check: (Bool, String) -> Void) {
        let saved = preferences.load()
        defer {
            preferences.setAutoKillEnabled(saved.autoKillEnabled)
            preferences.setUserPorts(saved.userPorts)
            preferences.setRuntimes(saved.runtimes)
            preferences.setIndicators(saved.indicators)
            preferences.setExclusions(saved.exclusions)
        }
        preferences.setAutoKillEnabled(false)
        preferences.setUserPorts([3_000])
        let terminations = OSAllocatedUnfairLock(initialState: 0)
        let service = DevCleanupService(
            username: "synthetic-owner",
            processProvider: { [
                DevCleanupProcess(pid: 100_991, user: "synthetic-owner", elapsedSeconds: 1,
                                  command: "/synthetic/other-worker"),
                DevCleanupProcess(pid: 100_992, user: "synthetic-owner", elapsedSeconds: 1,
                                  command: "/synthetic/synthetic-runtime /synthetic/synthetic-worker"),
                DevCleanupProcess(pid: 100_993, user: "synthetic-owner", elapsedSeconds: 1,
                                  command: "/synthetic/synthetic-runtime /synthetic/synthetic-worker protected-worker")
            ] },
            listeningPortsProvider: { [100_991: [7_654], 100_992: [7_655], 100_993: [7_656]] },
            terminator: { _ in terminations.withLock { $0 += 1 }; return false }
        )
        let monitor = DevCleanupMonitor(preferences: preferences, service: service)
        defer { monitor.stop() }
        monitor.start(allowAutomaticTermination: false)
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        let released = DispatchSemaphore(value: 0)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        monitor.performanceEnqueue {
            if released.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
        }
        monitor.refreshPorts()
        preferences.setUserPorts([7_654])
        preferences.setRuntimes(["synthetic-runtime"])
        preferences.setIndicators(["synthetic-worker"])
        preferences.setExclusions(["protected-worker"])
        released.signal()
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        check(monitor.portProcesses.map(\.pid) == [100_991, 100_992],
              "Queued port scans must use the latest saved ports, runtimes, indicators, and exclusions at admission.")
        check(terminations.withLock { $0 } == 0, "A read-only synthetic port scan must never terminate a process.")
        check(!timedOut.withLock { $0 }, "The queued settings scan must not time out.")
    }

    private static func cleanupVisitResumptionChecks(preferences: DevCleanupPreferences, _ check: (Bool, String) -> Void) {
        let savedAutoKill = preferences.load().autoKillEnabled
        defer { preferences.setAutoKillEnabled(savedAutoKill) }
        preferences.setAutoKillEnabled(false)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let terminations = OSAllocatedUnfairLock(initialState: 0)
        let service = DevCleanupService(
            username: "synthetic-owner",
            processProvider: {
                reads.withLock { $0 += 1 }
                return [DevCleanupProcess(
                    pid: 100_995, user: "synthetic-owner", elapsedSeconds: 1_000_000,
                    command: "/synthetic/node /synthetic/vite/bin/vite.js"
                )]
            },
            listeningPortsProvider: { [100_995: [3_000]] },
            terminator: { _ in terminations.withLock { $0 += 1 }; return false }
        )
        let monitor = DevCleanupMonitor(preferences: preferences, service: service)
        defer { monitor.stop() }
        var visit = UUID()
        var observedMonitor: DevCleanupMonitor?
        var search: Binding<String>?
        let controller = NSHostingController(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        func render() {
            let previousReads = reads.withLock { $0 }
            var page = DevCleanupTab(
                allowAutomaticTermination: .constant(false),
                visitID: Binding(get: { visit }, set: { visit = $0 }),
                entryPending: false, requestConfirmation: {}, showDevServers: {},
                preferences: preferences, monitor: monitor
            )
            page.performanceObserveState = { model, query, _ in observedMonitor = model; search = query }
            controller.rootView = AnyView(page.environment(\.allowsLiveOperations, true))
            controller.view.layoutSubtreeIfNeeded()
            let readDeadline = Date().addingTimeInterval(2)
            while reads.withLock({ $0 }) == previousReads && Date() < readDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            monitor.performanceDrainWorkQueue()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        render()
        guard let search else {
            check(false, "The synthetic read-only page must expose its retained search state.")
            return
        }
        check(reads.withLock { $0 > 0 }, "The first read-only cleanup visit must start its mock session.")
        search.wrappedValue = "synthetic retained query"
        for transition in ["coalesced hide/show", "coalesced away/back"] {
            let before = reads.withLock { $0 }
            monitor.stop()
            visit = UUID()
            if transition == "coalesced away/back" { visit = UUID() }
            render()
            check(reads.withLock { $0 > before },
                  "Read-only cleanup must restart after \(transition) even when its content never disappears.")
            check(observedMonitor === monitor && search.wrappedValue == "synthetic retained query",
                  "A new cleanup visit must retain its model and filters without retaining its canceled session.")
            check(!monitor.cleanupConfiguration().autoKillEnabled,
                  "Read-only resumption must not grant automatic termination.")
        }
        let beforeManualRefresh = reads.withLock { $0 }
        monitor.refreshPorts()
        monitor.runCleanup()
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        check(reads.withLock { $0 } >= beforeManualRefresh + 2,
              "A resumed read-only session must admit its manual scan and cleanup requests.")
        check(terminations.withLock { $0 } == 0, "Read-only resumption must never invoke the synthetic terminator.")
    }

    private static func copyFeedbackChecks(_ check: (Bool, String) -> Void) {
        var copied: Binding<Bool>?
        var revision: Binding<Int>?
        var button = CopyInspectionTextButton(title: "Copy fixture", value: "synthetic clipboard text")
        button.performanceObserveFeedback = { copied = $0; revision = $1 }
        let controller = NSHostingController(rootView: AnyView(button.environment(\.allowsLiveOperations, false)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard let copied, let revision else {
            check(false, "The synthetic copy button must expose feedback without touching the system clipboard.")
            return
        }
        copied.wrappedValue = true
        revision.wrappedValue += 1
        RunLoop.current.run(until: Date().addingTimeInterval(1.9))
        check(!copied.wrappedValue, "Inspection copy confirmation must expire rather than staying Copied indefinitely.")
        copied.wrappedValue = true
        revision.wrappedValue += 1
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        revision.wrappedValue += 1
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        check(copied.wrappedValue, "A repeated copy must not be cleared by its predecessor's expiration.")
        RunLoop.current.run(until: Date().addingTimeInterval(1.1))
        check(!copied.wrappedValue, "The latest copy must expire after its own feedback interval.")
        copied.wrappedValue = true
        revision.wrappedValue += 1
        controller.rootView = AnyView(EmptyView())
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(!copied.wrappedValue, "Hiding a copy button must clear confirmation without changing the real clipboard.")
    }

    private static func queuedMetricVisibilityChecks(_ check: (Bool, String) -> Void) {
        for metric: ResourceMetric in [.energy, .memory] {
            let monitor = ResourceMonitor()
            monitor.setMetric(metric, owner: UUID())
            check(monitor.performanceEffectiveMetric == metric, "The synthetic metric lease must be installed.")
            let released = DispatchSemaphore(value: 0)
            let observed = DispatchSemaphore(value: 0)
            let received = OSAllocatedUnfairLock<ResourceMetric?>(initialState: nil)
            let timedOut = OSAllocatedUnfairLock(initialState: false)
            monitor.performanceEnqueue {
                if released.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
            }
            monitor.performanceReadQueuedMetric { value in
                received.withLock { $0 = value }
                observed.signal()
            }
            monitor.setWindowVisible(false)
            released.signal()
            check(observed.wait(timeout: .now() + 2) == .success, "The synthetic queued metric callback must run.")
            check(received.withLock { $0 } == nil,
                  "Queued \(metric.rawValue) collection must see hidden-window state before sampling begins.")
            check(!timedOut.withLock { $0 }, "The controlled metric queue must not time out.")
        }
    }

    private static func energyPhaseAdmissionChecks(_ check: (Bool, String) -> Void) {
        let battery = BatteryResourceSummary(source: "Synthetic power", chargePercent: 80, status: "Synthetic", timeRemaining: nil)
        for revokedAfter in ["power", "sleep assertions"] {
            let sampler = ResourceSampler()
            var allowed = true
            var phases: [String] = []
            let sampled = sampler.performanceCollectEnergy(
                allowsCollection: { allowed },
                readPower: {
                    phases.append("power")
                    if revokedAfter == "power" { allowed = false }
                    return [100_000: 1]
                },
                readSleepAssertions: {
                    phases.append("sleep assertions")
                    if revokedAfter == "sleep assertions" { allowed = false }
                    return []
                },
                readBattery: { phases.append("battery"); return battery }
            )
            let expected = revokedAfter == "power" ? ["power"] : ["power", "sleep assertions"]
            check(phases == expected, "Revoking Energy during \(revokedAfter) must not admit later collectors.")
            check(!sampled, "Revoked Energy must not publish a completed optional sample.")
        }
        let sampler = ResourceSampler()
        var phases: [String] = []
        let sampled = sampler.performanceCollectEnergy(
            allowsCollection: { true },
            readPower: { phases.append("power"); return [100_000: 1] },
            readSleepAssertions: { phases.append("sleep assertions"); return [] },
            readBattery: { phases.append("battery"); return battery }
        )
        check(sampled && phases == ["power", "sleep assertions", "battery"],
              "An admitted Energy sample must retain all three collector phases.")
        phases = []
        let canceled = sampler.performanceCollectEnergy(
            allowsCollection: { false },
            readPower: { phases.append("power"); return [:] },
            readSleepAssertions: { phases.append("sleep assertions"); return [] },
            readBattery: { phases.append("battery"); return battery }
        )
        check(!canceled && phases.isEmpty, "Already-revoked Energy must not invoke any collector.")
        let cached = ResourceSampler()
        _ = cached.performanceCollectEnergy(
            allowsCollection: { true }, readPower: { [:] }, readSleepAssertions: { [] }, readBattery: { battery }
        )
        check(cached.performanceCachedBattery?.chargePercent == 80, "An admitted Energy reading must cache its synthetic battery.")
        _ = cached.performanceCollectEnergy(
            allowsCollection: { false }, readPower: { [:] }, readSleepAssertions: { [] }, readBattery: { battery }
        )
        check(cached.performanceCachedBattery == nil, "Revoked Energy must clear optional cached battery measurements.")
        _ = cached.performanceCollectEnergy(
            allowsCollection: { true }, readPower: { [:] }, readSleepAssertions: { [] },
            readBattery: { throw ProcessInspectionError(message: "Synthetic battery unavailable.") }
        )
        let warning = cached.performanceBatteryWarning
        _ = cached.performanceCollectEnergy(
            allowsCollection: { false }, readPower: { [:] }, readSleepAssertions: { [] }, readBattery: { battery }
        )
        check(cached.performanceCachedBattery == nil && warning != nil && cached.performanceBatteryWarning == warning,
              "Revocation clears cached battery values without silently discarding an unresolved reader warning.")
    }

    private static func resetAuthorizationChecks(preferences: DevCleanupPreferences, _ check: (Bool, String) -> Void) {
        let savedAutoKill = preferences.load().autoKillEnabled
        defer { preferences.setAutoKillEnabled(savedAutoKill) }
        preferences.setAutoKillEnabled(false)
        let terminated = OSAllocatedUnfairLock(initialState: [Int32]())
        let service = DevCleanupService(
            username: "synthetic-owner",
            processProvider: { [DevCleanupProcess(
                pid: 100_997, user: "synthetic-owner", elapsedSeconds: 1_000_000,
                command: "/synthetic/node /synthetic/vite/bin/vite.js"
            )] },
            listeningPortsProvider: { [100_997: [3_000]] },
            terminator: { pid in terminated.withLock { $0.append(pid) }; return true }
        )
        let monitor = DevCleanupMonitor(preferences: preferences, service: service)
        defer { monitor.stop() }
        monitor.start(allowAutomaticTermination: false)
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        monitor.resetToDefaults()
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(terminated.withLock { $0.isEmpty } && !monitor.cleanupConfiguration().autoKillEnabled,
              "Reset defaults must not authorize automatic termination during an unconfirmed read-only visit.")
        monitor.autoKillEnabled = true
        monitor.runCleanup()
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(terminated.withLock { $0.isEmpty }, "Changing the auto-kill setting alone must not grant visit authorization.")
        monitor.prepareForEntry(allowAutomaticTermination: true)
        monitor.runCleanup()
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(terminated.withLock { $0 } == [100_997], "Explicit authorization must still permit the injected qualifying cleanup.")
        let released = DispatchSemaphore(value: 0)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        monitor.performanceEnqueue {
            if released.wait(timeout: .now() + 5) != .success { timedOut.withLock { $0 = true } }
        }
        monitor.runCleanup()
        monitor.prepareForEntry(allowAutomaticTermination: false)
        released.signal()
        monitor.performanceDrainWorkQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(terminated.withLock { $0 } == [100_997], "Revoking authorization must also gate a previously queued cleanup request.")
        monitor.stop()
        check(!monitor.cleanupConfiguration().autoKillEnabled, "Stopping the visit must revoke permission despite retained enabled settings.")
        check(!timedOut.withLock { $0 }, "The authorization-revocation queue must not time out.")
    }

    private static func thermalPresentationChecks(_ check: (Bool, String) -> Void) {
        let health = SystemHealthMonitor()
        let status = SystemStatusStrip(monitor: health, navigate: { _ in })
        check(status.performanceBatteryValue == "Collecting battery information",
              "The dashboard battery shortcut must report collection, not unavailability, before its first snapshot.")
        check(status.performanceThermalValue == "Collecting thermal information",
              "The dashboard thermal shortcut must distinguish initial collection from completed unavailable data.")
        var observed = false
        var state: SystemThermalState? = .unavailable
        var page = SystemHealthTab(monitor: health, resources: ResourceMonitor(), page: .thermal)
        page.performanceObserveThermalState = { observed = true; state = $0 }
        let controller = NSHostingController(rootView: AnyView(page.environment(\.allowsLiveOperations, false)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(observed && state == nil, "Thermal UI must show pending data, not a read failure, before its first snapshot.")
        health.publishPerformanceFixture()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(state == .nominal, "Thermal UI must show the measured state after a successful synthetic read.")
        check(status.performanceThermalValue == SystemThermalState.nominal.rawValue,
              "The thermal shortcut must replace its pending text with the measured state.")
        if case .available(let battery) = health.snapshot?.battery, let percent = battery.chargePercent {
            check(status.performanceBatteryValue == "Battery \(percent)%",
                  "The dashboard battery shortcut must replace pending text with the measured charge.")
        } else { check(false, "The synthetic battery shortcut fixture must have readable charge data.") }
        health.publishPerformanceFixture(thermalState: .unavailable)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(state == .unavailable, "A completed unavailable thermal reading must remain distinct from pending data.")
        check(status.performanceThermalValue == SystemThermalState.unavailable.rawValue,
              "A completed unavailable thermal shortcut must not revert to its collecting state.")
    }

    private static func filteredProjectWarningChecks(_ check: (Bool, String) -> Void) {
        let inspection = ProcessInspectionMonitor()
        let rows = Array(inspection.connections.prefix(2))
        guard rows.count == 2, let identity = inspection.identities[rows[1].pid] else {
            check(false, "Synthetic listener identities must be available.")
            return
        }
        let errors = [identity: "Synthetic project metadata is unavailable."]
        check(!DevServersTab.hasProjectWarnings(in: rows.prefix(1), identities: inspection.identities, errors: errors),
              "A project error on a filtered-out listener must not raise an unexplained visible warning.")
        check(DevServersTab.hasProjectWarnings(in: rows.suffix(1), identities: inspection.identities, errors: errors),
              "A visible affected listener must still raise its project warning.")
        check(!DevServersTab.hasProjectWarnings(in: [NetworkConnectionRecord](), identities: inspection.identities, errors: errors),
              "No matching listeners must not claim that visible rows explain hidden project errors.")
    }

    private static func dashboardSelectionChecks(_ check: (Bool, String) -> Void) {
        let monitor = ResourceMonitor()
        let controller = RetainedPageController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        var selection: Binding<Date?>?
        func showDashboard() {
            var page = ActivityDashboard(monitor: monitor, systemHealth: SystemHealthMonitor(), navigate: { _ in })
            page.performanceObserveScrubber = { selection = $0 }
            controller.show(.dashboard, content: AnyView(page.environment(\.allowsLiveOperations, false)))
            controller.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        showDashboard()
        guard let selection, let otherRange = ActivityHistoryRange.allCases.first(where: { $0 != monitor.historyRange }) else {
            check(false, "The isolated dashboard must expose a scrubber and history ranges.")
            return
        }
        let date = Date()
        selection.wrappedValue = date
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let originalSelectionID = monitor.historySelectionID
        monitor.publishPerformanceSample(fixture(date: date, count: 1, step: 0))
        check(monitor.historySelectionID == originalSelectionID, "Ordinary resource samples must not invalidate a scrubbed time.")
        controller.show(.resources, content: AnyView(Text("Synthetic resource page")))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        showDashboard()
        check(selection.wrappedValue == date, "Navigation with an unchanged history selection must preserve its inspected time.")
        controller.show(.resources, content: AnyView(Text("Synthetic resource page")))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let originalRange = monitor.historyRange
        monitor.historyRange = otherRange
        monitor.historyRange = originalRange
        showDashboard()
        check(selection.wrappedValue == nil, "Returning after coalesced history-range changes must not restore a stale scrubbed date.")
        selection.wrappedValue = date
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        controller.show(.resources, content: AnyView(Text("Synthetic resource page")))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        monitor.focusedProcess = ActivityProcessIdentity(bootSession: "synthetic-dashboard", pid: 100_996, startTime: 1)
        monitor.focusedProcess = nil
        showDashboard()
        check(selection.wrappedValue == nil, "Returning after coalesced process changes must not restore a stale scrubbed date.")
    }

    private static func processDetailObservationChecks(_ check: (Bool, String) -> Void) {
        let resources = ResourceMonitor()
        resources.showAllUsers = true
        let date = Date()
        resources.publishPerformanceSample(fixture(date: date, count: 1_000, step: 0))
        guard let process = resources.liveActivity?.processes.first?.process else {
            check(false, "The synthetic inspector must have a process lifetime.")
            return
        }
        var renderCount = 0
        var currentUpdates = 0
        var current: ResourceProcess?
        var page = ProcessDetailSheet(process: process, resourceMonitor: resources)
        page.performanceObserveBody = { renderCount += 1 }
        page.performanceObserveCurrent = { currentUpdates += 1; current = $0 }
        let controller = NSHostingController(rootView: AnyView(page.environment(\.allowsLiveOperations, false)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let initialRenders = renderCount
        let initialUpdates = currentUpdates
        resources.publishPerformanceSample(fixture(date: date.addingTimeInterval(6), count: 1_000, step: 1))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(initialRenders > 0 && renderCount == initialRenders,
              "A resource tick must not rebuild the inspector's unrelated file/connection queries and tables.")
        check(currentUpdates > initialUpdates && current?.identity == process.identity,
              "The inspector's resource header must still receive current readings for the selected lifetime.")
    }

    private static func healthObservationChecks(_ check: (Bool, String) -> Void) {
        for pageID: MainTab in [.battery, .thermal, .system] {
            let health = SystemHealthMonitor()
            health.publishPerformanceFixture()
            let resources = ResourceMonitor()
            var renderCount = 0
            var cpu: CPUResourceSummary?
            var page = SystemHealthTab(monitor: health, resources: resources, page: pageID)
            page.performanceObserveBody = { renderCount += 1 }
            page.performanceObserveCPU = { cpu = $0 }
            let controller = NSHostingController(rootView: AnyView(page.environment(\.allowsLiveOperations, false)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            controller.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let initial = renderCount
            resources.publishPerformanceSample(fixture(date: Date(), count: 1, step: 1))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            check(renderCount == initial, "\(pageID.title) must not rebuild for unrelated six-second resource ticks.")
            if pageID == .system {
                check(cpu?.processCount == 1 && cpu?.userPercent == 11, "The System CPU leaf must still update to the synthetic resource reading.")
            }
            window.contentViewController = nil
            window.close()
        }
    }

    private static func fixture(date: Date, count: Int, step: Int) -> ResourceSnapshot {
        let processes = (0..<count).map { index in
            ResourceProcess(
                identity: ActivityProcessIdentity(
                    bootSession: "synthetic-benchmark-boot", pid: Int32(100_000 + index), startTime: UInt64(index + 1)
                ),
                pid: Int32(100_000 + index), name: "Synthetic worker \(index)", user: "synthetic-user",
                cpu: Double((index + step) % 100) / 10, cpuTimeSeconds: Double(index + step),
                threads: 4, idleWakeUps: UInt64(index), kind: "Apple",
                memoryBytes: UInt64(index % 50 + 1) * 1_048_576, openFileCount: 12,
                power: Double(index % 5), power12Hour: nil, appNap: nil, preventsSleep: false,
                diskReadBytes: UInt64(index + step) * 4_096, diskWrittenBytes: UInt64(index + step) * 2_048,
                diskSampledAt: date, networkSampledAt: date,
                receivedBytes: UInt64(index + step) * 1_024, sentBytes: UInt64(index + step) * 512,
                receivedPackets: UInt64(index + step), sentPackets: UInt64(index + step), icon: nil
            )
        }
        let descriptors = processes.compactMap { process in
            process.identity.map { ActivityProcessDescriptor(identity: $0, name: process.name, user: process.user) }
        }
        return ResourceSnapshot(
            date: date, processes: processes, processInventory: ActivityProcessInventory(processes: descriptors),
            cpu: CPUResourceSummary(
                userPercent: Double(step % 30 + 10), systemPercent: 8, idlePercent: Double(82 - step % 30),
                processCount: count, runningCount: 3, threadCount: count * 4
            ),
            memory: MemoryResourceSummary(
                physicalBytes: 16 * 1_073_741_824, usedBytes: 8 * 1_073_741_824,
                appBytes: 5 * 1_073_741_824, cachedBytes: 2 * 1_073_741_824, wiredBytes: 1_073_741_824,
                compressedBytes: 1_073_741_824, swapUsedBytes: 0, pressurePercent: 30
            ),
            disk: DiskResourceSummary(
                capacity: DiskCapacity(totalBytes: 512 * 1_073_741_824, freeBytes: 256 * 1_073_741_824),
                reads: 100, readBytes: 4_096_000, writes: 50, writtenBytes: 2_048_000,
                readsPerSecond: 10, readBytesPerSecond: 40_960, writesPerSecond: 5, writtenBytesPerSecond: 20_480
            ),
            network: NetworkResourceSummary(
                receivedPackets: 100, receivedBytes: 1_024_000, sentPackets: 50, sentBytes: 512_000,
                receivedPacketsPerSecond: 10, receivedBytesPerSecond: 10_240, sentPacketsPerSecond: 5,
                sentBytesPerSecond: 5_120
            ),
            battery: BatteryResourceSummary(source: "AC Power", chargePercent: 80, status: "charging", timeRemaining: nil),
            sampledEnergy: true, warnings: []
        )
    }
}

private struct ProbeStateView: View {
    let record: (UUID) -> Void
    let activation: (Bool) -> Void
    @State private var token = UUID()
    @Environment(\.isKillSwitchPageVisible) private var pageVisible
    var body: some View {
        Group {
            if pageVisible {
                ProbeStateRecorder(token: token, record: record)
                    .frame(width: 20, height: 20)
                    .onAppear { activation(true) }
                    .onDisappear { activation(false) }
            }
        }
    }
}

private struct ProbeStateRecorder: NSViewRepresentable {
    let token: UUID
    let record: (UUID) -> Void
    func makeNSView(context: Context) -> NSView { record(token); return NSView() }
    func updateNSView(_ view: NSView, context: Context) { record(token) }
}
#endif
