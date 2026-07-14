import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.storage
import SystemMetricsCore
import os

enum ResourceMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case energy = "Energy"
    case disk = "Disk"
    case network = "Network"

    var id: Self { self }
}

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
    let pid: Int32
    let name: String
    let user: String
    let cpu: Double
    let cpuTimeSeconds: Double
    let threads: Int
    let idleWakeUps: UInt64?
    let kind: String?
    let gpu: Double?
    let gpuTimeSeconds: Double?
    let memoryBytes: UInt64
    let ports: Int
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
    let cpuUser: Double
    let cpuSystem: Double
    let memoryPressure: Double
    let energyImpact: Double
    let diskReadRate: Double
    let diskWriteRate: Double
    let networkReceiveRate: Double
    let networkSendRate: Double
}

private struct DiskCounters {
    let reads: UInt64
    let readBytes: UInt64
    let writes: UInt64
    let writtenBytes: UInt64
}

private struct NetworkCounters {
    let receivedPackets: UInt64
    let receivedBytes: UInt64
    let sentPackets: UInt64
    let sentBytes: UInt64
}

private struct ResourceSnapshot {
    let date: Date
    let processes: [ResourceProcess]
    let cpu: CPUResourceSummary
    let memory: MemoryResourceSummary
    let disk: DiskResourceSummary
    let network: NetworkResourceSummary
    let battery: BatteryResourceSummary
}

private final class ResourceSampler {
    private let username = NSUserName()
    private var previousDisk: (date: Date, counters: DiskCounters)?
    private var previousNetwork: (date: Date, counters: NetworkCounters)?

    func sample(includeAllUsers: Bool) throws -> ResourceSnapshot {
        var topArguments = [
            "-l", "2",
            "-n", "10000",
            "-s", "1",
            "-F",
            "-R",
            "-ncols", "512",
            "-stats", "pid,cpu,time,threads,idlew,power,mem,ports,user,command",
            "-o", "cpu"
        ]
        if !includeAllUsers {
            topArguments.append(contentsOf: ["-user", username])
        }

        let topResult = try CommandRunner.run(
            "/usr/bin/top",
            arguments: topArguments,
            environment: ["LC_ALL": "C"]
        )
        guard topResult.succeeded else {
            let detail = topResult.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "KillSwitch.ResourceSampler",
                code: Int(topResult.status),
                userInfo: [
                    NSLocalizedDescriptionKey: detail.isEmpty
                        ? "The system process sampler exited with status \(topResult.status)."
                        : detail
                ]
            )
        }

        let top = try SystemMetricsParser.parseTop(topResult.standardOutput)
        let networkProcesses = sampleNetworkProcesses()
        let preventingSleep = samplePreventingSleepPIDs()
        let applications = runningApplications()

        var processes: [ResourceProcess] = []
        processes.reserveCapacity(top.processes.count)
        for process in top.processes {
            let metadata = processMetadata(pid: process.pid, applications: applications)
            let disk = processDiskUsage(pid: process.pid)
            let network = networkProcesses[process.pid] ?? .zero

            processes.append(
                ResourceProcess(
                    pid: process.pid,
                    name: metadata.name ?? process.command,
                    user: process.user,
                    cpu: process.cpu,
                    cpuTimeSeconds: process.cpuTimeSeconds,
                    threads: process.threads,
                    idleWakeUps: process.idleWakeUps,
                    kind: metadata.kind,
                    gpu: nil,
                    gpuTimeSeconds: nil,
                    memoryBytes: process.memoryBytes,
                    ports: process.ports,
                    power: process.power,
                    power12Hour: nil,
                    appNap: nil,
                    preventsSleep: preventingSleep.contains(process.pid),
                    diskReadBytes: disk?.read,
                    diskWrittenBytes: disk?.written,
                    receivedBytes: network.receivedBytes,
                    sentBytes: network.sentBytes,
                    receivedPackets: network.receivedPackets,
                    sentPackets: network.sentPackets,
                    icon: metadata.icon
                )
            )
        }

        let now = Date()
        let diskCounters = sampleDiskCounters()
        let networkCounters = sampleNetworkCounters()
        let diskSummary = makeDiskSummary(now: now, counters: diskCounters)
        let networkSummary = makeNetworkSummary(now: now, counters: networkCounters)

        return ResourceSnapshot(
            date: now,
            processes: processes,
            cpu: CPUResourceSummary(
                userPercent: top.cpu.userPercent,
                systemPercent: top.cpu.systemPercent,
                idlePercent: top.cpu.idlePercent,
                processCount: top.cpu.processCount,
                runningCount: top.cpu.runningCount,
                threadCount: top.cpu.threadCount
            ),
            memory: sampleMemory(),
            disk: diskSummary,
            network: networkSummary,
            battery: sampleBattery()
        )
    }

    private func sampleNetworkProcesses() -> [Int32: ParsedNetworkProcess] {
        guard
            let result = try? CommandRunner.run(
                "/usr/bin/nettop",
                arguments: [
                    "-P", "-L", "1", "-x",
                    "-J", "packets_in,bytes_in,packets_out,bytes_out"
                ],
                environment: ["LC_ALL": "C"]
            ),
            result.succeeded
        else {
            return [:]
        }
        return SystemMetricsParser.parseNetworkProcesses(result.standardOutput)
    }

    private func sampleNetworkCounters() -> NetworkCounters {
        guard
            let result = try? CommandRunner.run(
                "/usr/sbin/netstat",
                arguments: ["-ibn"],
                environment: ["LC_ALL": "C"]
            ),
            result.succeeded,
            let totals = SystemMetricsParser.parseNetworkTotals(result.standardOutput)
        else {
            return NetworkCounters(receivedPackets: 0, receivedBytes: 0, sentPackets: 0, sentBytes: 0)
        }

        return NetworkCounters(
            receivedPackets: totals.receivedPackets,
            receivedBytes: totals.receivedBytes,
            sentPackets: totals.sentPackets,
            sentBytes: totals.sentBytes
        )
    }

    private func samplePreventingSleepPIDs() -> Set<Int32> {
        guard
            let result = try? CommandRunner.run("/usr/bin/pmset", arguments: ["-g", "assertions"]),
            result.succeeded
        else {
            return []
        }
        return SystemMetricsParser.parsePreventingSleepPIDs(result.standardOutput)
    }

    private func sampleBattery() -> BatteryResourceSummary {
        guard
            let result = try? CommandRunner.run("/usr/bin/pmset", arguments: ["-g", "batt"]),
            result.succeeded
        else {
            return .unavailable
        }
        let battery = SystemMetricsParser.parseBattery(result.standardOutput)
        return BatteryResourceSummary(
            source: battery.source,
            chargePercent: battery.chargePercent,
            status: battery.status,
            timeRemaining: battery.timeRemaining
        )
    }

    private func sampleMemory() -> MemoryResourceSummary {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return .unavailable }

        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .unavailable }

        let pageBytes = UInt64(pageSize)
        let physical = ProcessInfo.processInfo.physicalMemory
        let free = (UInt64(statistics.free_count) + UInt64(statistics.speculative_count)) * pageBytes
        let cached = (UInt64(statistics.external_page_count) + UInt64(statistics.purgeable_count)) * pageBytes
        let appPages = UInt64(statistics.internal_page_count) > UInt64(statistics.purgeable_count)
            ? UInt64(statistics.internal_page_count) - UInt64(statistics.purgeable_count)
            : 0
        let used = physical > free + cached ? physical - free - cached : 0

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let pressure: Double?
        if let command = try? CommandRunner.run("/usr/bin/memory_pressure", arguments: ["-Q"]),
           command.succeeded,
           let freePercentage = SystemMetricsParser.parseMemoryPressureFreePercentage(command.standardOutput) {
            pressure = max(0, min(100, 100 - freePercentage))
        } else {
            pressure = nil
        }

        return MemoryResourceSummary(
            physicalBytes: physical,
            usedBytes: used,
            appBytes: appPages * pageBytes,
            cachedBytes: cached,
            wiredBytes: UInt64(statistics.wire_count) * pageBytes,
            compressedBytes: UInt64(statistics.compressor_page_count) * pageBytes,
            swapUsedBytes: swapResult == 0 ? swap.xsu_used : 0,
            pressurePercent: pressure
        )
    }

    private func sampleDiskCounters() -> DiskCounters {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else {
            return DiskCounters(reads: 0, readBytes: 0, writes: 0, writtenBytes: 0)
        }
        defer { IOObjectRelease(iterator) }

        var reads: UInt64 = 0
        var readBytes: UInt64 = 0
        var writes: UInt64 = 0
        var writtenBytes: UInt64 = 0

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let property = IORegistryEntryCreateCFProperty(
                service,
                kIOBlockStorageDriverStatisticsKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] {
                reads += (property[kIOBlockStorageDriverStatisticsReadsKey] as? NSNumber)?.uint64Value ?? 0
                readBytes += (property[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber)?.uint64Value ?? 0
                writes += (property[kIOBlockStorageDriverStatisticsWritesKey] as? NSNumber)?.uint64Value ?? 0
                writtenBytes += (property[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return DiskCounters(reads: reads, readBytes: readBytes, writes: writes, writtenBytes: writtenBytes)
    }

    private func makeDiskSummary(now: Date, counters: DiskCounters) -> DiskResourceSummary {
        defer { previousDisk = (now, counters) }
        guard let previousDisk else {
            return DiskResourceSummary(
                reads: counters.reads,
                readBytes: counters.readBytes,
                writes: counters.writes,
                writtenBytes: counters.writtenBytes,
                readsPerSecond: nil,
                readBytesPerSecond: nil,
                writesPerSecond: nil,
                writtenBytesPerSecond: nil
            )
        }

        let elapsed = now.timeIntervalSince(previousDisk.date)
        return DiskResourceSummary(
            reads: counters.reads,
            readBytes: counters.readBytes,
            writes: counters.writes,
            writtenBytes: counters.writtenBytes,
            readsPerSecond: rate(current: counters.reads, previous: previousDisk.counters.reads, elapsed: elapsed),
            readBytesPerSecond: rate(
                current: counters.readBytes,
                previous: previousDisk.counters.readBytes,
                elapsed: elapsed
            ),
            writesPerSecond: rate(
                current: counters.writes,
                previous: previousDisk.counters.writes,
                elapsed: elapsed
            ),
            writtenBytesPerSecond: rate(
                current: counters.writtenBytes,
                previous: previousDisk.counters.writtenBytes,
                elapsed: elapsed
            )
        )
    }

    private func makeNetworkSummary(now: Date, counters: NetworkCounters) -> NetworkResourceSummary {
        defer { previousNetwork = (now, counters) }
        guard let previousNetwork else {
            return NetworkResourceSummary(
                receivedPackets: counters.receivedPackets,
                receivedBytes: counters.receivedBytes,
                sentPackets: counters.sentPackets,
                sentBytes: counters.sentBytes,
                receivedPacketsPerSecond: nil,
                receivedBytesPerSecond: nil,
                sentPacketsPerSecond: nil,
                sentBytesPerSecond: nil
            )
        }

        let elapsed = now.timeIntervalSince(previousNetwork.date)
        return NetworkResourceSummary(
            receivedPackets: counters.receivedPackets,
            receivedBytes: counters.receivedBytes,
            sentPackets: counters.sentPackets,
            sentBytes: counters.sentBytes,
            receivedPacketsPerSecond: rate(
                current: counters.receivedPackets,
                previous: previousNetwork.counters.receivedPackets,
                elapsed: elapsed
            ),
            receivedBytesPerSecond: rate(
                current: counters.receivedBytes,
                previous: previousNetwork.counters.receivedBytes,
                elapsed: elapsed
            ),
            sentPacketsPerSecond: rate(
                current: counters.sentPackets,
                previous: previousNetwork.counters.sentPackets,
                elapsed: elapsed
            ),
            sentBytesPerSecond: rate(
                current: counters.sentBytes,
                previous: previousNetwork.counters.sentBytes,
                elapsed: elapsed
            )
        )
    }

    private func processDiskUsage(pid: Int32) -> (read: UInt64, written: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return (info.ri_diskio_bytesread, info.ri_diskio_byteswritten)
    }

    private func processMetadata(
        pid: Int32,
        applications: [Int32: (name: String, icon: NSImage?)]
    ) -> (name: String?, icon: NSImage?, kind: String?) {
        let application = applications[pid]
        let pathName = processPath(pid: pid).map { URL(fileURLWithPath: $0).lastPathComponent }
        return (
            application?.name ?? pathName,
            application?.icon,
            processKind(pid: pid)
        )
    }

    private func processPath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_pidpath(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func processKind(pid: Int32) -> String? {
        var info = proc_archinfo()
        let size = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDARCHINFO, 0, pointer, Int32(MemoryLayout<proc_archinfo>.size))
        }
        guard size == MemoryLayout<proc_archinfo>.size else { return nil }
        switch info.p_cputype {
        case CPU_TYPE_ARM64:
            return "Apple"
        case CPU_TYPE_X86_64:
            return "Intel"
        default:
            return nil
        }
    }

    private func runningApplications() -> [Int32: (name: String, icon: NSImage?)] {
        var result: [Int32: (name: String, icon: NSImage?)] = [:]
        for application in NSWorkspace.shared.runningApplications {
            let pid = application.processIdentifier
            guard let name = application.localizedName, !name.isEmpty else { continue }
            result[pid] = (name, application.icon)
        }
        return result
    }

    private func rate(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, current >= previous else { return nil }
        return Double(current - previous) / elapsed
    }
}

final class ResourceMonitor: ObservableObject {
    @Published private(set) var processes: [ResourceProcess] = []
    @Published private(set) var cpu = CPUResourceSummary.unavailable
    @Published private(set) var memory = MemoryResourceSummary.unavailable
    @Published private(set) var disk = DiskResourceSummary.unavailable
    @Published private(set) var network = NetworkResourceSummary.unavailable
    @Published private(set) var battery = BatteryResourceSummary.unavailable
    @Published private(set) var history: [ResourceHistoryPoint] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published var showAllUsers = false {
        didSet {
            let newValue = showAllUsers
            samplingQueue.async { [weak self] in
                self?.includeAllUsers = newValue
                self?.sampleNow()
            }
        }
    }

    let currentUsername = NSUserName()

    private struct EnergySample {
        let date: Date
        let value: Double
    }

    private let sampler = ResourceSampler()
    private let samplingQueue = DispatchQueue(label: "killswitch.resources.sampling", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "resources")
    private var timer: DispatchSourceTimer?
    private var includeAllUsers = false
    private var energyHistory: [Int32: [EnergySample]] = [:]
    private var lastEnergyHistorySample: Date?

    func start() {
        samplingQueue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.includeAllUsers = self.showAllUsers
            let timer = DispatchSource.makeTimerSource(queue: self.samplingQueue)
            timer.schedule(deadline: .now(), repeating: 6, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.sampleNow() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        samplingQueue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    func refresh() {
        samplingQueue.async { [weak self] in self?.sampleNow() }
    }

    func kill(pid: Int32) {
        ProcessSampler.terminate(pid: pid)
        samplingQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sampleNow()
        }
    }

    private func sampleNow() {
        do {
            let snapshot = try sampler.sample(includeAllUsers: includeAllUsers)
            var sampledProcesses = snapshot.processes
            updateEnergyHistory(processes: sampledProcesses, now: snapshot.date)

            for index in sampledProcesses.indices {
                let samples = energyHistory[sampledProcesses[index].pid] ?? []
                if !samples.isEmpty {
                    sampledProcesses[index].power12Hour =
                        samples.reduce(0) { $0 + $1.value } / Double(samples.count)
                } else {
                    sampledProcesses[index].power12Hour = sampledProcesses[index].power
                }
            }

            let point = ResourceHistoryPoint(
                date: snapshot.date,
                cpuUser: snapshot.cpu.userPercent,
                cpuSystem: snapshot.cpu.systemPercent,
                memoryPressure: snapshot.memory.pressurePercent ?? 0,
                energyImpact: sampledProcesses.reduce(0) { $0 + $1.power },
                diskReadRate: snapshot.disk.readBytesPerSecond ?? 0,
                diskWriteRate: snapshot.disk.writtenBytesPerSecond ?? 0,
                networkReceiveRate: snapshot.network.receivedBytesPerSecond ?? 0,
                networkSendRate: snapshot.network.sentBytesPerSecond ?? 0
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.processes = sampledProcesses
                self.cpu = snapshot.cpu
                self.memory = snapshot.memory
                self.disk = snapshot.disk
                self.network = snapshot.network
                self.battery = snapshot.battery
                self.history.append(point)
                let cutoff = snapshot.date.addingTimeInterval(-300)
                self.history.removeAll { $0.date < cutoff }
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
        for process in processes.sorted(by: { $0.power > $1.power }).prefix(50) where process.power > 0 {
            energyHistory[process.pid, default: []].append(EnergySample(date: now, value: process.power))
        }

        for pid in energyHistory.keys {
            energyHistory[pid]?.removeAll { $0.date < cutoff }
            if energyHistory[pid]?.isEmpty == true {
                energyHistory.removeValue(forKey: pid)
            }
        }
    }
}
