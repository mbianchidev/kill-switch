import Foundation
import SwiftUI
import SystemMetricsCore
import os

@MainActor
final class SystemHealthMonitor: ObservableObject {
    static let shared = SystemHealthMonitor()
    @Published private(set) var hardware: SystemHardwareInfo?
    @Published private(set) var snapshot: SystemHealthSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    private var clients: Set<UUID> = []
    private let hasVisibleClient = OSAllocatedUnfairLock(initialState: false)
    private let windowVisible = OSAllocatedUnfairLock(initialState: true)
    private var timer: Timer?
    private var scheduledRefreshID: UUID?
    private var nextAutomaticRefreshAt: ContinuousClock.Instant?
    private var refreshID: UUID?
    private var hardwareError: String?
    private let now: () -> ContinuousClock.Instant
    private let readHardware: @Sendable () throws -> SystemHardwareInfo
    private let readSnapshot: @Sendable () -> SystemHealthSnapshot
    private let queue = DispatchQueue(label: "killswitch.system-health", qos: .utility, autoreleaseFrequency: .workItem)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "system-health")

    init(
        now: @escaping () -> ContinuousClock.Instant = { .now },
        readHardware: @escaping @Sendable () throws -> SystemHardwareInfo = { try SystemHealthReader.hardware() },
        readSnapshot: @escaping @Sendable () -> SystemHealthSnapshot = { SystemHealthReader.sample() }
    ) {
        self.now = now
        self.readHardware = readHardware
        self.readSnapshot = readSnapshot
    }

    func setActive(_ active: Bool, client: UUID) {
        if active { clients.insert(client) } else { clients.remove(client) }
        let visible = !clients.isEmpty
        hasVisibleClient.withLock { $0 = visible }
        if clients.isEmpty {
            cancelTimer()
        } else if timer == nil {
            refreshAutomatically()
        }
    }

    func setWindowVisible(_ visible: Bool) {
        windowVisible.withLock { $0 = visible }
        if visible { refreshAutomatically() } else { cancelTimer() }
    }

    func refresh() {
        guard !clients.isEmpty, windowVisible.withLock({ $0 }), refreshID == nil else { return }
        cancelTimer()
        let id = UUID()
        let needsHardware = hardware == nil
        let readHardware = readHardware
        let readSnapshot = readSnapshot
        let hasVisibleClient = hasVisibleClient
        let windowVisible = windowVisible
        refreshID = id
        isRefreshing = true
        queue.async { [weak self] in
            guard hasVisibleClient.withLock({ $0 }) && windowVisible.withLock({ $0 }) else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.refreshID == id else { return }
                    self.refreshID = nil
                    self.isRefreshing = false
                    self.refreshAutomatically()
                }
                return
            }
            let hardware = needsHardware ? Result { try readHardware() } : nil
            let snapshot = readSnapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refreshID == id else { return }
                self.refreshID = nil
                self.isRefreshing = false
                self.nextAutomaticRefreshAt = self.now().advanced(by: .seconds(30))
                // A page handoff does not invalidate a machine-wide reading.
                if let hardware {
                    switch hardware {
                    case .success(let value):
                        self.hardware = value
                        self.hardwareError = nil
                    case .failure(let error):
                        self.hardwareError = error.localizedDescription
                    }
                }
                self.snapshot = snapshot
                let errors = [self.hardwareError].compactMap { $0 } + snapshot.warnings
                self.errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
                if let message = self.errorMessage { self.logger.error("System health: \(message)") }
                self.scheduleAutomaticRefresh()
            }
        }
    }

    private func refreshAutomatically() {
        guard !clients.isEmpty, windowVisible.withLock({ $0 }), refreshID == nil else { return }
        if let nextAutomaticRefreshAt, now() < nextAutomaticRefreshAt {
            scheduleAutomaticRefresh()
        } else {
            refresh()
        }
    }

    private func scheduleAutomaticRefresh() {
        guard !clients.isEmpty, windowVisible.withLock({ $0 }), refreshID == nil, let nextAutomaticRefreshAt else { return }
        cancelTimer()
        let remaining = now().duration(to: nextAutomaticRefreshAt).components
        let delay = max(0, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
        let id = UUID()
        scheduledRefreshID = id
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scheduledRefreshID == id else { return }
                self.timer = nil
                self.scheduledRefreshID = nil
                self.refreshAutomatically()
            }
        }
        timer?.tolerance = min(3, delay / 10)
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
        scheduledRefreshID = nil
    }

    func shutdown() {
        clients.removeAll()
        hasVisibleClient.withLock { $0 = false }
        cancelTimer()
    }

#if KILLSWITCH_PERFORMANCE_PROBE
    func performanceEnqueue(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    var performanceHasScheduledRefresh: Bool { timer?.isValid == true }

    func performanceFireAutomaticRefresh() {
        timer?.fire()
        timer?.invalidate()
    }

    func publishPerformanceFixture(thermalState: SystemThermalState = .nominal) {
        hardware = SystemHardwareInfo(
            model: "Synthetic Mac", cpuName: "Synthetic CPU", architecture: "Apple Silicon",
            physicalCPUCount: 8, logicalCPUCount: 8, activeCPUCount: 8,
            physicalMemoryBytes: 16 * 1_073_741_824, operatingSystem: "Synthetic macOS", kernelVersion: "Synthetic kernel"
        )
        snapshot = SystemHealthSnapshot(
            date: Date(), thermalState: thermalState, lowPowerMode: false, uptime: 86_400,
            loadAverages: [1, 1.5, 2], powerSource: .mains,
            battery: .available(SystemBatteryReading(
                currentCapacity: 80, maximumCapacity: 100, isCharging: true, isFullyCharged: false,
                minutesToEmpty: nil, minutesToFull: 30, cycleCount: 42, condition: "Good"
            )), warnings: []
        )
    }
#endif
}

private struct SystemHealthSampling: ViewModifier {
    let monitor: SystemHealthMonitor
    @State private var client = UUID()
    @Environment(\.isKillSwitchWindowVisible) private var visible
    @Environment(\.allowsLiveOperations) private var allowsOperations

    private var active: Bool { visible && allowsOperations }

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.setActive(active, client: client) }
            .onChange(of: active) { active in monitor.setActive(active, client: client) }
            .onDisappear { monitor.setActive(false, client: client) }
    }
}

extension View {
    func systemHealthSampling(_ monitor: SystemHealthMonitor) -> some View {
        modifier(SystemHealthSampling(monitor: monitor))
    }
}
