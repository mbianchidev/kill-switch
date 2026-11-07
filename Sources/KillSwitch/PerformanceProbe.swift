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
    static func run(arguments: [String]) -> Int32 {
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
               "connections", "files", "servers", "inspector", "navigation"].contains(arguments[0]),
              let duration = Double(arguments[1]), (3...600).contains(duration),
              let count = Int(arguments[2]), (1...5_000).contains(count) else {
            fputs("Usage: performance-probe SCENARIO SECONDS(3...600) PROCESSES(1...5000) [OFFSCREEN.png [WIDTHxHEIGHT]]; or --interface-checks\n", stderr)
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
        if scenario == "background" {
            view = nil
            window = nil
        } else {
            let root: AnyView
            if scenario == "dashboard" || scenario == "navigation" {
                root = AnyView(ContentView(resourceMonitor: monitor, startsServices: false))
            } else if ["cpu", "memory", "energy"].contains(scenario) {
                let metric: ResourceMetric = scenario == "memory" ? .memory : scenario == "energy" ? .energy : .cpu
                root = AnyView(ResourcesTab(monitor: monitor, initialMetric: metric))
            } else if scenario == "inspector", let process = monitor.liveActivity?.processes.first?.process {
                root = AnyView(ProcessDetailSheet(process: process, resourceMonitor: monitor))
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
                root = AnyView(ContentView(resourceMonitor: monitor, initialTab: page, startsServices: false))
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
        let start = Date()
        var nextSample = start
        var step = 51
        while Date().timeIntervalSince(start) < duration {
            if Date() >= nextSample {
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
                nextSample = nextSample.addingTimeInterval(6)
            }
            autoreleasepool {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
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
        let energyDate = Date()
        for index in 0..<61 {
            monitor.publishPerformanceSample(fixture(
                date: energyDate.addingTimeInterval(Double(index - 60) * 6), count: 1_000, step: index
            ))
        }
        check(monitor.history[.energy]?.count == 51, "Energy probes must populate and prune the full five-minute chart.")
        check(monitor.history[.energy]?.last?.primary == 2_000, "Energy chart fixtures must contain measured power totals.")
        healthPollingChecks(check)
        queuedInspectionChecks(check)

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
        reactivated.refresh()
        reactivated.stop()
        reactivated.start(.connections)
        reactivated.refresh()
        reactivationReleased.signal()
        let modes = reactivated.performanceSampleModes
        check(!modes.isEmpty && modes.allSatisfy { $0 == .connections },
              "A new inspection activation must collect only its current mode, not queued work from its predecessor.")
        check(!timedOut.withLock { $0 }, "Controlled synthetic inspection queues must not time out.")
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
        func showCleanup(entryPending: Bool) {
            var page = DevCleanupTab(
                allowAutomaticTermination: false, entryPending: entryPending,
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
