import AppKit
import Foundation
import SystemMetricsCore
import os

typealias ResourceMetric = ResourceMetricKind

enum ResourceSort: String, Identifiable {
    case cpu = "% CPU"
    case memory = "Memory"
    case energy = "Energy impact"
    case diskWritten = "Bytes written"
    case diskRead = "Bytes read"
    case networkReceived = "Received bytes"
    case networkSent = "Sent bytes"
    case name = "Name"
    case pid = "PID"

    var id: Self { self }

    static func options(for metric: ResourceMetric) -> [ResourceSort] {
        switch metric {
        case .cpu:
            return [.cpu, .name, .pid]
        case .memory:
            return [.memory, .name, .pid]
        case .energy:
            return [.energy, .name, .pid]
        case .disk:
            return [.diskWritten, .diskRead, .name, .pid]
        case .network:
            return [.networkReceived, .networkSent, .name, .pid]
        }
    }

    static func defaultOption(for metric: ResourceMetric) -> ResourceSort {
        options(for: metric)[0]
    }
}

struct ResourceProcess: Identifiable {
    let identity: ResourceProcessIdentity?
    let pid: Int32
    let name: String
    let user: String
    let cpu: Double
    let cpuTimeSeconds: Double
    let threads: Int?
    let idleWakeUps: UInt64?
    let kind: String?
    let gpu: Double?
    let gpuTimeSeconds: Double?
    let memoryBytes: UInt64
    let openFileCount: Int?
    let power: Double
    var power12Hour: Double?
    let appNap: Bool?
    let preventsSleep: Bool
    let diskReadBytes: UInt64?
    let diskWrittenBytes: UInt64?
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let receivedPackets: UInt64
    let sentPackets: UInt64
    let icon: NSImage?

    var id: Int32 { pid }
}

struct ResourceProcessIdentity: Hashable {
    let pid: Int32
    let startTime: UInt64
}

struct CPUResourceSummary {
    let userPercent: Double
    let systemPercent: Double
    let idlePercent: Double
    let processCount: Int
    let runningCount: Int
    let threadCount: Int

    static let unavailable = CPUResourceSummary(
        userPercent: 0,
        systemPercent: 0,
        idlePercent: 0,
        processCount: 0,
        runningCount: 0,
        threadCount: 0
    )
}

struct MemoryResourceSummary {
    let physicalBytes: UInt64
    let usedBytes: UInt64
    let appBytes: UInt64
    let cachedBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let swapUsedBytes: UInt64
    let pressurePercent: Double?

    static let unavailable = MemoryResourceSummary(
        physicalBytes: 0,
        usedBytes: 0,
        appBytes: 0,
        cachedBytes: 0,
        wiredBytes: 0,
        compressedBytes: 0,
        swapUsedBytes: 0,
        pressurePercent: nil
    )
}

struct DiskResourceSummary {
    let reads: UInt64
    let readBytes: UInt64
    let writes: UInt64
    let writtenBytes: UInt64
    let readsPerSecond: Double?
    let readBytesPerSecond: Double?
    let writesPerSecond: Double?
    let writtenBytesPerSecond: Double?

    static let unavailable = DiskResourceSummary(
        reads: 0,
        readBytes: 0,
        writes: 0,
        writtenBytes: 0,
        readsPerSecond: nil,
        readBytesPerSecond: nil,
        writesPerSecond: nil,
        writtenBytesPerSecond: nil
    )
}

struct NetworkResourceSummary {
    let receivedPackets: UInt64
    let receivedBytes: UInt64
    let sentPackets: UInt64
    let sentBytes: UInt64
    let receivedPacketsPerSecond: Double?
    let receivedBytesPerSecond: Double?
    let sentPacketsPerSecond: Double?
    let sentBytesPerSecond: Double?

    static let unavailable = NetworkResourceSummary(
        receivedPackets: 0,
        receivedBytes: 0,
        sentPackets: 0,
        sentBytes: 0,
        receivedPacketsPerSecond: nil,
        receivedBytesPerSecond: nil,
        sentPacketsPerSecond: nil,
        sentBytesPerSecond: nil
    )
}

struct BatteryResourceSummary {
    let source: String
    let chargePercent: Int?
    let status: String
    let timeRemaining: String?

    static let unavailable = BatteryResourceSummary(
        source: "Unknown",
        chargePercent: nil,
        status: "Unavailable",
        timeRemaining: nil
    )
}

struct ResourceHistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let primary: Double
    let secondary: Double?
}

final class ResourceMonitor: ObservableObject {
    @Published private(set) var processes: [ResourceProcess] = []
    @Published private(set) var cpu = CPUResourceSummary.unavailable
    @Published private(set) var memory = MemoryResourceSummary.unavailable
    @Published private(set) var disk = DiskResourceSummary.unavailable
    @Published private(set) var network = NetworkResourceSummary.unavailable
    @Published private(set) var battery = BatteryResourceSummary.unavailable
    @Published private(set) var history: [ResourceMetric: [ResourceHistoryPoint]] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published var showAllUsers = false {
        didSet {
            let newValue = showAllUsers
            samplingQueue.async { [weak self] in
                guard let self else { return }
                self.includeAllUsers = newValue
                self.restartTimer(sampleImmediately: true)
            }
        }
    }

    let currentUsername = NSUserName()

    private struct EnergySample {
        let date: Date
        let value: Double
    }

    private let sampler = ResourceSampler()
    private let samplingQueue = DispatchQueue(label: "killswitch.resources.sampling", qos: .utility)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "resources")
    private var timer: DispatchSourceTimer?
    private var includeAllUsers = false
    private var activeMetric: ResourceMetric = .cpu
    private var energyHistory: [ResourceProcessIdentity: [EnergySample]] = [:]
    private var lastEnergyHistorySample: Date?
    private var running = false

    func start() {
        let includeAllUsers = showAllUsers
        samplingQueue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.includeAllUsers = includeAllUsers
            self.sampler.resetBaselines()
            self.restartTimer(sampleImmediately: true)
        }
    }

    func stop() {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            self.sampler.resetBaselines()
        }
    }

    func refresh() {
        samplingQueue.async { [weak self] in
            self?.restartTimer(sampleImmediately: true)
        }
    }

    func setMetric(_ metric: ResourceMetric) {
        samplingQueue.async { [weak self] in
            guard let self, self.activeMetric != metric else { return }
            self.activeMetric = metric
            if metric == .network {
                self.sampler.resetNetworkBaseline()
            }
            self.restartTimer(sampleImmediately: true)
        }
    }

    func kill(pid: Int32) {
        ProcessSampler.terminate(pid: pid)
        samplingQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restartTimer(sampleImmediately: true)
        }
    }

    private func restartTimer(sampleImmediately: Bool) {
        timer?.cancel()
        timer = nil
        guard running else { return }

        let policy = ResourceSamplingPolicy.forMetric(activeMetric)
        let interval = TimeInterval(policy.intervalSeconds)
        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        timer.schedule(
            deadline: sampleImmediately ? .now() : .now() + interval,
            repeating: interval,
            leeway: .seconds(max(1, min(5, policy.intervalSeconds / 6)))
        )
        timer.setEventHandler { [weak self] in self?.sampleNow() }
        timer.resume()
        self.timer = timer
    }

    private func sampleNow() {
        guard running else { return }
        let metric = activeMetric

        do {
            let snapshot = try sampler.sample(metric: metric, includeAllUsers: includeAllUsers)
            var sampledProcesses = snapshot.processes
            if metric == .energy {
                updateEnergyHistory(processes: sampledProcesses, now: snapshot.date)
            }

            for index in sampledProcesses.indices {
                if let identity = sampledProcesses[index].identity,
                   let samples = energyHistory[identity],
                   !samples.isEmpty {
                    sampledProcesses[index].power12Hour =
                        samples.reduce(0) { $0 + $1.value } / Double(samples.count)
                } else {
                    sampledProcesses[index].power12Hour = nil
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.processes = sampledProcesses
                self.cpu = snapshot.cpu
                self.memory = snapshot.memory
                self.disk = snapshot.disk
                if let network = snapshot.network {
                    self.network = network
                }
                if let battery = snapshot.battery {
                    self.battery = battery
                }
                if let point = snapshot.historyPoint {
                    self.history[metric, default: []].append(point)
                    let cutoff = snapshot.date.addingTimeInterval(-300)
                    self.history[metric]?.removeAll { $0.date < cutoff }
                }
                self.lastUpdated = snapshot.date
                self.errorMessage = nil
            }
        } catch {
            logger.error("Resource sampling failed: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func updateEnergyHistory(processes: [ResourceProcess], now: Date) {
        if let lastEnergyHistorySample, now.timeIntervalSince(lastEnergyHistorySample) < 60 {
            return
        }
        lastEnergyHistorySample = now

        let cutoff = now.addingTimeInterval(-12 * 3_600)
        for process in processes.sorted(by: { $0.power > $1.power }).prefix(50)
        where process.power > 0 {
            guard let identity = process.identity else { continue }
            energyHistory[identity, default: []].append(EnergySample(date: now, value: process.power))
        }

        for identity in Array(energyHistory.keys) {
            energyHistory[identity]?.removeAll { $0.date < cutoff }
            if energyHistory[identity]?.isEmpty == true {
                energyHistory.removeValue(forKey: identity)
            }
        }
    }
}
