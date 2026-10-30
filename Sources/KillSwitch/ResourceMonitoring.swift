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
    let measuredCPU: Double?
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
    let diskSampledAt: Date?
    let networkSampledAt: Date?
    let receivedBytes: UInt64?
    let sentBytes: UInt64?
    let receivedPackets: UInt64?
    let sentPackets: UInt64?
    let icon: NSImage?

    var id: Int32 { pid }
}

typealias ResourceProcessIdentity = ActivityProcessIdentity

struct CPUResourceSummary {
    let userPercent: Double
    let systemPercent: Double
    let idlePercent: Double
    let processCount: Int
    let runningCount: Int
    let threadCount: Int
    var isAvailable = true

    static let unavailable = CPUResourceSummary(
        userPercent: 0,
        systemPercent: 0,
        idlePercent: 0,
        processCount: 0,
        runningCount: 0,
        threadCount: 0,
        isAvailable: false
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
    var capacity: DiskCapacity?
    let reads: UInt64
    let readBytes: UInt64
    let writes: UInt64
    let writtenBytes: UInt64
    let readsPerSecond: Double?
    let readBytesPerSecond: Double?
    let writesPerSecond: Double?
    let writtenBytesPerSecond: Double?
    var isAvailable = true

    static let unavailable = DiskResourceSummary(
        capacity: nil,
        reads: 0,
        readBytes: 0,
        writes: 0,
        writtenBytes: 0,
        readsPerSecond: nil,
        readBytesPerSecond: nil,
        writesPerSecond: nil,
        writtenBytesPerSecond: nil,
        isAvailable: false
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
    var isAvailable = true

    static let unavailable = NetworkResourceSummary(
        receivedPackets: 0,
        receivedBytes: 0,
        sentPackets: 0,
        sentBytes: 0,
        receivedPacketsPerSecond: nil,
        receivedBytesPerSecond: nil,
        sentPacketsPerSecond: nil,
        sentBytesPerSecond: nil,
        isAvailable: false
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
    static let shared = ResourceMonitor()

    @Published private(set) var processes: [ResourceProcess] = []
    @Published private(set) var cpu = CPUResourceSummary.unavailable
    @Published private(set) var memory = MemoryResourceSummary.unavailable
    @Published private(set) var disk = DiskResourceSummary.unavailable
    @Published private(set) var network = NetworkResourceSummary.unavailable
    @Published private(set) var battery = BatteryResourceSummary.unavailable
    @Published private(set) var history: [ResourceMetric: [ResourceHistoryPoint]] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var historyError: String?
    @Published private(set) var historyNotice: String?
    @Published private(set) var timeline: [ActivityHistoryPoint] = []
    @Published private(set) var historyProcesses: [ActivityProcessDescriptor] = []
    @Published private(set) var liveActivity: ActivitySnapshot?
    @Published var showAllUsers = false
    @Published var historyRange: ActivityHistoryRange = .live {
        didSet { reloadHistory() }
    }
    @Published var focusedProcess: ActivityProcessIdentity? {
        didSet { reloadHistory() }
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
    private var activeMetric: ResourceMetric?
    private var energyHistory: [ResourceProcessIdentity: [EnergySample]] = [:]
    private var lastEnergyHistorySample: Date?
    private var running = false
    private var store: ActivityHistoryStore?
    private var accumulator = ActivityAccumulator()
    private var writeBuffer = ActivityWriteBuffer()
    private var rates = ActivityRateTracker()
    private var liveSnapshots: [ActivitySnapshot] = []
    private var archivedProcesses: [ActivityProcessDescriptor] = []
    private var selectedRange: ActivityHistoryRange = .live
    private var selectedProcess: ActivityProcessIdentity?

    func start() {
        samplingQueue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.sampler.resetBaselines()
            self.openHistory()
            self.restartTimer(sampleImmediately: true)
        }
    }

    func shutdown() {
        samplingQueue.sync {
            running = false
            timer?.cancel()
            timer = nil
            if let current = accumulator.current {
                enqueueHistory(current, now: Date())
                flushPendingHistory(now: Date())
            }
        }
    }

    func refresh() {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            if self.store == nil { self.openHistory() }
            self.flushPendingHistory(now: Date())
            self.restartTimer(sampleImmediately: true)
        }
    }

    func setMetric(_ metric: ResourceMetric?) {
        samplingQueue.async { [weak self] in
            guard let self, self.activeMetric != metric else { return }
            self.activeMetric = metric
        }
    }

    func clearHistory() {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let store = self.store else {
                    throw ActivityHistoryError(message: "the database is unavailable; history could not be cleared.")
                }
                try store.clear()
                self.liveSnapshots.removeAll()
                self.archivedProcesses.removeAll()
                self.accumulator = ActivityAccumulator()
                self.writeBuffer = ActivityWriteBuffer()
                self.publishTimeline(now: Date())
                DispatchQueue.main.async {
                    self.historyError = nil
                    self.historyNotice = nil
                }
            } catch {
                self.reportHistoryError(error)
            }
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

        let interval = TimeInterval(ResourceSamplingPolicy.continuousIntervalSeconds)
        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        timer.schedule(
            deadline: sampleImmediately ? .now() : .now() + interval,
            repeating: interval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in self?.sampleNow() }
        timer.resume()
        self.timer = timer
    }

    private func sampleNow() {
        guard running else { return }
        let metric = activeMetric

        do {
            let snapshot = try sampler.sample(metric: metric)
            var sampledProcesses = snapshot.processes
            if snapshot.sampledEnergy {
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

            let activity = activitySnapshot(snapshot)
            liveSnapshots.append(activity)
            liveSnapshots.removeAll { $0.date < snapshot.date.addingTimeInterval(-300) }
            if let completed = accumulator.append(activity) {
                enqueueHistory(completed, now: snapshot.date)
            }
            flushPendingHistory(now: snapshot.date)
            publishTimeline(now: snapshot.date)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.processes = sampledProcesses
                self.cpu = snapshot.cpu
                self.memory = snapshot.memory
                self.disk = snapshot.disk
                self.network = snapshot.network ?? .unavailable
                if let battery = snapshot.battery {
                    self.battery = battery
                }
                if snapshot.sampledEnergy {
                    self.history[.energy, default: []].append(ResourceHistoryPoint(
                        date: snapshot.date,
                        primary: sampledProcesses.reduce(0) { $0 + $1.power },
                        secondary: nil
                    ))
                    let cutoff = snapshot.date.addingTimeInterval(-300)
                    self.history[.energy]?.removeAll { $0.date < cutoff }
                }
                self.liveActivity = activity
                self.lastUpdated = snapshot.date
                self.errorMessage = snapshot.warnings.isEmpty ? nil : snapshot.warnings.joined(separator: "\n")
            }
        } catch {
            logger.error("Resource sampling failed: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func openHistory() {
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let url = applicationSupport.appendingPathComponent("KillSwitch/ActivityHistory/activity.sqlite")
            let historyStore = try ActivityHistoryStore(url: url)
            try historyStore.prune(now: Date())
            archivedProcesses = try historyStore.processes(since: Date().addingTimeInterval(-ActivityHistoryStore.retention))
            store = historyStore
            DispatchQueue.main.async { self.historyError = nil }
            publishTimeline(now: Date())
        } catch {
            reportHistoryError(error)
        }
    }

    private func reloadHistory() {
        let range = historyRange
        let process = focusedProcess
        samplingQueue.async { [weak self] in
            guard let self else { return }
            self.selectedRange = range
            self.selectedProcess = process
            self.publishTimeline(now: Date())
        }
    }

    private func publishTimeline(now: Date) {
        let cutoff = now.addingTimeInterval(-selectedRange.seconds)
        var points: [ActivityHistoryPoint] = []
        do {
            if let store {
                points = try store.history(process: selectedProcess, since: cutoff, until: now)
            }
        } catch {
            reportHistoryError(error)
        }
        let live = liveSnapshots.filter { $0.date >= cutoff }.map { $0.point(for: selectedProcess) }
        if let first = live.first {
            points.removeAll { $0.date >= first.date }
        }
        points.append(contentsOf: live)

        var descriptors = Dictionary(uniqueKeysWithValues: archivedProcesses.map { ($0.id, $0) })
        for sample in liveSnapshots.flatMap(\.processes) {
            descriptors[sample.process.id] = sample.process
        }
        let sorted = descriptors.values.sorted {
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if $0.identity.pid != $1.identity.pid { return $0.identity.pid < $1.identity.pid }
            return $0.identity.key < $1.identity.key
        }
        DispatchQueue.main.async {
            self.timeline = points
            self.historyProcesses = sorted
        }
    }

    private func activitySnapshot(_ snapshot: ResourceSnapshot) -> ActivitySnapshot {
        let samples = snapshot.processes.compactMap { process -> ActivityProcessSample? in
            guard let identity = process.identity else { return nil }
            let rate = rates.sample(
                identity: identity, date: snapshot.date,
                diskRead: process.diskReadBytes, diskWritten: process.diskWrittenBytes,
                received: process.receivedBytes, sent: process.sentBytes,
                diskDate: process.diskSampledAt, networkDate: process.networkSampledAt
            )
            return ActivityProcessSample(
                process: ActivityProcessDescriptor(identity: identity, name: process.name, user: process.user),
                values: ActivityValues(
                    cpu: process.measuredCPU, memory: Double(process.memoryBytes),
                    diskRead: rate.diskRead, diskWritten: rate.diskWritten,
                    received: rate.received, sent: rate.sent
                )
            )
        }
        rates.retain(Set(samples.map(\.process.identity)))
        return ActivitySnapshot(
            date: snapshot.date,
            system: ActivityValues(
                cpu: snapshot.cpu.isAvailable ? snapshot.cpu.userPercent + snapshot.cpu.systemPercent : nil,
                memory: snapshot.memory.physicalBytes > 0 ? Double(snapshot.memory.usedBytes) : nil,
                diskRead: snapshot.disk.readBytesPerSecond, diskWritten: snapshot.disk.writtenBytesPerSecond,
                received: snapshot.network?.receivedBytesPerSecond, sent: snapshot.network?.sentBytesPerSecond,
                cpuSystem: snapshot.cpu.isAvailable ? snapshot.cpu.systemPercent : nil,
                cpuUser: snapshot.cpu.isAvailable ? snapshot.cpu.userPercent : nil
            ),
            processes: samples
        )
    }

    private func reportHistoryError(_ error: Error) {
        logger.error("Activity history failed: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.historyError = "History could not be saved or loaded: \(error.localizedDescription) Refresh to retry."
        }
    }

    private func enqueueHistory(_ snapshot: ActivitySnapshot, now: Date) {
        if writeBuffer.append(snapshot, now: now) > 0 {
            logger.error("Unsaved activity history expired after five minutes of storage failures.")
            DispatchQueue.main.async {
                self.historyNotice = "Some older measurements could not be saved while history storage was unavailable."
            }
        }
    }

    private func flushPendingHistory(now: Date) {
        guard writeBuffer.count > 0, let store else { return }
        do {
            try writeBuffer.flush { try store.save($0, now: now) }
            archivedProcesses = try store.processes(since: now.addingTimeInterval(-ActivityHistoryStore.retention))
            DispatchQueue.main.async { self.historyError = nil }
        } catch {
            reportHistoryError(error)
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
