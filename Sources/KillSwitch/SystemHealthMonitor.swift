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
    private var timer: Timer?
    private var generation = 0
    private var refreshID: UUID?
    private var hardwareError: String?
    private let queue = DispatchQueue(label: "killswitch.system-health", qos: .utility, autoreleaseFrequency: .workItem)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "system-health")

    func setActive(_ active: Bool, client: UUID) {
        if active { clients.insert(client) } else { clients.remove(client) }
        if clients.isEmpty {
            timer?.invalidate()
            timer = nil
            generation += 1
        } else if timer == nil {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            }
            timer?.tolerance = 3
        }
    }

    func refresh() {
        guard !clients.isEmpty, refreshID == nil else { return }
        let id = UUID()
        let generation = generation
        let needsHardware = hardware == nil
        refreshID = id
        isRefreshing = true
        queue.async { [weak self] in
            let hardware = needsHardware ? Result { try SystemHealthReader.hardware() } : nil
            let snapshot = SystemHealthReader.sample()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refreshID == id else { return }
                self.refreshID = nil
                self.isRefreshing = false
                guard self.generation == generation, !self.clients.isEmpty else {
                    if !self.clients.isEmpty { self.refresh() }
                    return
                }
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
            }
        }
    }

    func shutdown() {
        clients.removeAll()
        timer?.invalidate()
        timer = nil
        generation += 1
    }

#if KILLSWITCH_PERFORMANCE_PROBE
    func publishPerformanceFixture() {
        hardware = SystemHardwareInfo(
            model: "Synthetic Mac", cpuName: "Synthetic CPU", architecture: "Apple Silicon",
            physicalCPUCount: 8, logicalCPUCount: 8, activeCPUCount: 8,
            physicalMemoryBytes: 16 * 1_073_741_824, operatingSystem: "Synthetic macOS", kernelVersion: "Synthetic kernel"
        )
        snapshot = SystemHealthSnapshot(
            date: Date(), thermalState: .nominal, lowPowerMode: false, uptime: 86_400,
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

    func body(content: Content) -> some View {
        content
            .onAppear { update() }
            .onChange(of: visible) { _ in update() }
            .onChange(of: allowsOperations) { _ in update() }
            .onDisappear { monitor.setActive(false, client: client) }
    }

    private func update() { monitor.setActive(visible && allowsOperations, client: client) }
}

extension View {
    func systemHealthSampling(_ monitor: SystemHealthMonitor) -> some View {
        modifier(SystemHealthSampling(monitor: monitor))
    }
}
