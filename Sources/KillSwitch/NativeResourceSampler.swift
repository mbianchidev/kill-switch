import AppKit
import Darwin
import Foundation
import InstallCore
import IOKit
import IOKit.storage
import SystemMetricsCore

struct ResourceSnapshot {
    let date: Date
    let processes: [ResourceProcess]
    let cpu: CPUResourceSummary
    let memory: MemoryResourceSummary
    let disk: DiskResourceSummary
    let network: NetworkResourceSummary?
    let battery: BatteryResourceSummary?
    let sampledEnergy: Bool
    let warnings: [String]
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

private struct NativeProcess {
    let identity: ResourceProcessIdentity
    let pid: Int32
    let name: String
    let user: String
    let cpu: Double?
    let cpuTimeSeconds: Double
    let threads: Int?
    let idleWakeUps: UInt64
    let kind: String?
    let memoryBytes: UInt64
    let openFileCount: Int
    let diskReadBytes: UInt64
    let diskWrittenBytes: UInt64
    let sampledAt: Date
    let icon: NSImage?
}

private struct ProcessMetadata {
    let name: String
    let kind: String?
}

final class ResourceSampler {
    private var previousProcessCPU: [ResourceProcessIdentity: (date: Date, nanoseconds: UInt64)] = [:]
    private var previousProcessDate: Date?
    private var previousSystemCPU: SystemCPUTicks?
    private var previousDisk: (date: Date, counters: DiskCounters)?
    private var previousNetwork: (date: Date, counters: NetworkCounters)?
    private var metadata: [ResourceProcessIdentity: ProcessMetadata] = [:]
    private var usernames: [uid_t: String] = [:]
    private var reportedDiskCapacityError = false
    private var identities: [Int32: ResourceProcessIdentity] = [:]
    private let bootSession = ResourceSampler.bootSessionIdentifier()
    private var lastEnergyDate: Date?
    private var cachedPower: [ResourceProcessIdentity: Double] = [:]
    private var cachedPreventingSleep: Set<ResourceProcessIdentity> = []
    private var cachedBattery: BatteryResourceSummary?

    func resetBaselines() {
        previousProcessCPU.removeAll()
        previousProcessDate = nil
        previousSystemCPU = nil
        previousDisk = nil
        previousNetwork = nil
    }

    func sample(metric: ResourceMetric?) throws -> ResourceSnapshot {
        let now = Date()
        let policy = ResourceSamplingPolicy.forMetric(metric ?? .cpu)
        if let previousProcessDate {
            let elapsed = now.timeIntervalSince(previousProcessDate)
            if elapsed <= 0 || elapsed > 30 { resetBaselines() }
        }
        var warnings: [String] = []
        let beforePS = sampleLifetimeIdentities()
        let applications = runningApplications()
        let parsedProcesses = try samplePSProcesses()
        let afterPS = sampleLifetimeIdentities()
        let nativeProcesses = sampleNativeProcesses(
            applications: applications, beforePS: beforePS, afterPS: afterPS
        )
        var sampledEnergy = false
        if policy.usesTop && (lastEnergyDate.map { now.timeIntervalSince($0) >= Double(policy.intervalSeconds) } ?? true) {
            do {
                let power = try samplePower()
                cachedPower = Dictionary(uniqueKeysWithValues: power.compactMap { pid, value in
                    identities[pid].map { ($0, value) }
                })
                cachedPreventingSleep = Set(samplePreventingSleepPIDs().compactMap { identities[$0] })
                cachedBattery = sampleBattery()
                lastEnergyDate = now
                sampledEnergy = true
            } catch {
                warnings.append("Energy: \(error.localizedDescription)")
            }
        }
        var networkProcesses: [Int32: ParsedNetworkProcess] = [:]
        var networkSampledAt: Date?
        do {
            networkProcesses = try sampleNetworkProcesses()
            networkSampledAt = Date()
        } catch {
            warnings.append("Process traffic: \(error.localizedDescription)")
        }
        identities = identities.filter { pid, identity in
            ProcessLifetimeReader.read(pid: pid, bootSession: bootSession) == identity
        }

        var processes: [ResourceProcess] = []
        processes.reserveCapacity(parsedProcesses.count)
        var includedPIDs: Set<Int32> = []

        for process in parsedProcesses {
            let identity = ResourceProcessIdentity.verified(
                pid: process.pid, before: beforePS, after: afterPS, current: identities[process.pid]
            )
            if identity == nil && nativeProcesses[process.pid] != nil { continue }
            includedPIDs.insert(process.pid)
            let native = identity == nil ? nil : nativeProcesses[process.pid]
            let application = identity == nil ? nil : applications[process.pid]
            let network = identity == nil ? nil : networkProcesses[process.pid]
            let fallbackName = SystemMetricsParser.executableName(process.command)

            processes.append(
                ResourceProcess(
                    identity: identity,
                    pid: process.pid,
                    name: application?.name ?? native?.name ?? fallbackName,
                    user: native?.user ?? process.user,
                    cpu: native?.cpu ?? process.cpu,
                    measuredCPU: native?.cpu,
                    cpuTimeSeconds: native?.cpuTimeSeconds ?? process.cpuTimeSeconds,
                    threads: native?.threads,
                    idleWakeUps: native?.idleWakeUps,
                    kind: native?.kind,
                    gpu: nil,
                    gpuTimeSeconds: nil,
                    memoryBytes: native?.memoryBytes ?? process.memoryBytes,
                    openFileCount: native?.openFileCount,
                    power: identity.flatMap { cachedPower[$0] } ?? 0,
                    power12Hour: nil,
                    appNap: nil,
                    preventsSleep: identity.map { cachedPreventingSleep.contains($0) } ?? false,
                    diskReadBytes: native?.diskReadBytes,
                    diskWrittenBytes: native?.diskWrittenBytes,
                    diskSampledAt: native?.sampledAt,
                    networkSampledAt: network == nil ? nil : networkSampledAt,
                    receivedBytes: network?.receivedBytes,
                    sentBytes: network?.sentBytes,
                    receivedPackets: network?.receivedPackets,
                    sentPackets: network?.sentPackets,
                    icon: application?.icon ?? native?.icon
                )
            )
        }

        for native in nativeProcesses.values
        where !includedPIDs.contains(native.pid) && identities[native.pid] == native.identity {
            let network = networkProcesses[native.pid]
            processes.append(
                ResourceProcess(
                    identity: native.identity,
                    pid: native.pid,
                    name: native.name,
                    user: native.user,
                    cpu: native.cpu ?? 0,
                    measuredCPU: native.cpu,
                    cpuTimeSeconds: native.cpuTimeSeconds,
                    threads: native.threads,
                    idleWakeUps: native.idleWakeUps,
                    kind: native.kind,
                    gpu: nil,
                    gpuTimeSeconds: nil,
                    memoryBytes: native.memoryBytes,
                    openFileCount: native.openFileCount,
                    power: cachedPower[native.identity] ?? 0,
                    power12Hour: nil,
                    appNap: nil,
                    preventsSleep: cachedPreventingSleep.contains(native.identity),
                    diskReadBytes: native.diskReadBytes,
                    diskWrittenBytes: native.diskWrittenBytes,
                    diskSampledAt: native.sampledAt,
                    networkSampledAt: network == nil ? nil : networkSampledAt,
                    receivedBytes: network?.receivedBytes,
                    sentBytes: network?.sentBytes,
                    receivedPackets: network?.receivedPackets,
                    sentPackets: network?.sentPackets,
                    icon: native.icon
                )
            )
        }

        let cpu = sampleCPU(processes: parsedProcesses)
        let memory = sampleMemory(includePressure: policy.collectsMemoryPressure)
        if !cpu.isAvailable && previousSystemCPU == nil {
            warnings.append("CPU rates need two readable samples.")
        }
        if memory.physicalBytes == 0 {
            warnings.append("macOS did not provide memory statistics.")
        }
        let capacity = sampleDiskCapacity()
        let disk: DiskResourceSummary
        do {
            let counters = try sampleDiskCounters()
            disk = makeDiskSummary(now: Date(), counters: counters, capacity: capacity)
        } catch {
            previousDisk = nil
            var unavailable = DiskResourceSummary.unavailable
            unavailable.capacity = capacity
            disk = unavailable
            warnings.append("Disk activity: \(error.localizedDescription)")
        }
        let network: NetworkResourceSummary?
        do {
            let counters = try sampleNetworkCounters()
            network = makeNetworkSummary(now: Date(), counters: counters)
        } catch {
            previousNetwork = nil
            network = nil
            warnings.append("Network totals: \(error.localizedDescription)")
        }

        return ResourceSnapshot(
            date: Date(),
            processes: processes,
            cpu: cpu,
            memory: memory,
            disk: disk,
            network: network,
            battery: metric == .energy ? cachedBattery : nil,
            sampledEnergy: sampledEnergy,
            warnings: warnings
        )
    }

    private func samplePSProcesses() throws -> [ParsedPSProcess] {
        let result = try CommandRunner.run(
            "/bin/ps",
            arguments: ["-axo", "pid=,user=,state=,pcpu=,time=,rss=,comm="],
            environment: ["LC_ALL": "C"]
        )
        guard result.succeeded else {
            throw commandError(result, name: "process list")
        }
        let processes = SystemMetricsParser.parsePSProcesses(result.standardOutput)
        guard !processes.isEmpty else {
            throw parseError("The process list did not contain any readable rows.")
        }
        return processes
    }

    private func sampleNativeProcesses(
        applications: [Int32: (name: String, icon: NSImage?)],
        beforePS: [Int32: ResourceProcessIdentity],
        afterPS: [Int32: ResourceProcessIdentity]
    ) -> [Int32: NativeProcess] {
        var currentCPU: [ResourceProcessIdentity: (date: Date, nanoseconds: UInt64)] = [:]
        var activeIdentities: Set<ResourceProcessIdentity> = []
        var result: [Int32: NativeProcess] = [:]
        identities.removeAll(keepingCapacity: true)

        for pid in listPIDs() {
            guard let identity = ProcessLifetimeReader.read(pid: pid, bootSession: bootSession) else { continue }
            identities[pid] = identity
            guard let bsd = processBSDInfo(pid: pid), let usage = processUsage(pid: pid) else { continue }
            let sampledAt = Date()
            let application = ResourceProcessIdentity.verified(
                pid: pid, before: beforePS, after: afterPS, current: identity
            ) == nil ? nil : applications[pid]

            let totalCPU = usage.ri_user_time + usage.ri_system_time
            let task = processTaskInfo(pid: pid)
            let processMetadata = metadata(
                pid: pid,
                identity: identity,
                bsd: bsd,
                applicationName: application?.name
            )

            let cpu: Double?
            if let previousCPU = previousProcessCPU[identity] {
                cpu = SystemMetricsCalculator.processCPUPercent(
                    currentNanoseconds: totalCPU,
                    previousNanoseconds: previousCPU.nanoseconds,
                    elapsedSeconds: sampledAt.timeIntervalSince(previousCPU.date)
                )
            } else {
                cpu = nil
            }

            currentCPU[identity] = (sampledAt, totalCPU)
            activeIdentities.insert(identity)
            result[pid] = NativeProcess(
                identity: identity,
                pid: pid,
                name: processMetadata.name,
                user: username(for: bsd.pbi_uid),
                cpu: cpu,
                cpuTimeSeconds: Double(totalCPU) / 1_000_000_000,
                threads: task.map { Int($0.pti_threadnum) },
                idleWakeUps: usage.ri_interrupt_wkups,
                kind: processMetadata.kind,
                memoryBytes: usage.ri_phys_footprint != 0
                    ? usage.ri_phys_footprint
                    : usage.ri_resident_size,
                openFileCount: Int(bsd.pbi_nfiles),
                diskReadBytes: usage.ri_diskio_bytesread,
                diskWrittenBytes: usage.ri_diskio_byteswritten,
                sampledAt: sampledAt,
                icon: application?.icon
            )
        }

        previousProcessCPU = currentCPU
        previousProcessDate = Date()
        metadata = metadata.filter { activeIdentities.contains($0.key) }
        return result
    }

    private func sampleCPU(processes: [ParsedPSProcess]) -> CPUResourceSummary {
        guard let ticks = systemCPUTicks() else {
            previousSystemCPU = nil
            let tasks = taskSummary()
            return CPUResourceSummary(
                userPercent: 0,
                systemPercent: 0,
                idlePercent: 0,
                processCount: processes.count,
                runningCount: processes.filter(\.isRunning).count,
                threadCount: tasks.threadCount,
                isAvailable: false
            )
        }

        let available = previousSystemCPU != nil
        let usage = SystemMetricsCalculator.systemCPUUsage(current: ticks, previous: previousSystemCPU)
        previousSystemCPU = ticks
        let tasks = taskSummary()
        return CPUResourceSummary(
            userPercent: usage.userPercent,
            systemPercent: usage.systemPercent,
            idlePercent: usage.idlePercent,
            processCount: processes.count,
            runningCount: processes.filter(\.isRunning).count,
            threadCount: tasks.threadCount,
            isAvailable: available
        )
    }

    private func samplePower() throws -> [Int32: Double] {
        let arguments = [
            "-l", "2",
            "-n", "10000",
            "-s", "1",
            "-F",
            "-R",
            "-ncols", "512",
            "-stats", "pid,cpu,time,threads,idlew,power,mem,ports,user,command",
            "-o", "power"
        ]
        let result = try CommandRunner.run(
            "/usr/bin/top",
            arguments: arguments,
            environment: ["LC_ALL": "C"]
        )
        guard result.succeeded else {
            throw commandError(result, name: "energy sampler")
        }
        var power: [Int32: Double] = [:]
        for process in try SystemMetricsParser.parseTop(result.standardOutput).processes {
            power[process.pid] = process.power
        }
        return power
    }

    private func sampleNetworkProcesses() throws -> [Int32: ParsedNetworkProcess] {
        let result = try CommandRunner.run(
            "/usr/bin/nettop",
            arguments: [
                "-P", "-L", "1", "-x",
                "-J", "packets_in,bytes_in,packets_out,bytes_out"
            ],
            environment: ["LC_ALL": "C"]
        )
        guard result.succeeded else {
            throw commandError(result, name: "per-process network sampler")
        }
        return SystemMetricsParser.parseNetworkProcesses(result.standardOutput)
    }

    private func sampleNetworkCounters() throws -> NetworkCounters {
        let result = try CommandRunner.run(
            "/usr/sbin/netstat",
            arguments: ["-ibn"],
            environment: ["LC_ALL": "C"]
        )
        guard result.succeeded else {
            throw commandError(result, name: "network totals sampler")
        }
        guard let totals = SystemMetricsParser.parseNetworkTotals(result.standardOutput) else {
            throw parseError("The network totals sampler returned an unreadable response.")
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

    private func sampleMemory(includePressure: Bool) -> MemoryResourceSummary {
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
        if includePressure,
           let command = try? CommandRunner.run("/usr/bin/memory_pressure", arguments: ["-Q"]),
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

    private func sampleDiskCounters() throws -> DiskCounters {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else {
            throw parseError("macOS did not provide storage device statistics.")
        }
        defer { IOObjectRelease(iterator) }

        var reads: UInt64 = 0
        var readBytes: UInt64 = 0
        var writes: UInt64 = 0
        var writtenBytes: UInt64 = 0
        var foundStatistics = false

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let property = IORegistryEntryCreateCFProperty(
                service,
                kIOBlockStorageDriverStatisticsKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any],
               let readCount = property[kIOBlockStorageDriverStatisticsReadsKey] as? NSNumber,
               let readSize = property[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber,
               let writeCount = property[kIOBlockStorageDriverStatisticsWritesKey] as? NSNumber,
               let writeSize = property[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber {
                foundStatistics = true
                reads += readCount.uint64Value
                readBytes += readSize.uint64Value
                writes += writeCount.uint64Value
                writtenBytes += writeSize.uint64Value
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        guard foundStatistics else { throw parseError("No readable storage I/O counters were exposed by macOS.") }
        return DiskCounters(
            reads: reads,
            readBytes: readBytes,
            writes: writes,
            writtenBytes: writtenBytes
        )
    }

    private func sampleDiskCapacity() -> DiskCapacity? {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(
                forPath: FileManager.default.homeDirectoryForCurrentUser.path
            )
            guard
                let total = attributes[.systemSize] as? NSNumber,
                let free = attributes[.systemFreeSize] as? NSNumber
            else {
                reportDiskCapacityError("filesystem attributes omitted size or free-space values")
                return nil
            }

            reportedDiskCapacityError = false
            return DiskCapacity(totalBytes: total.uint64Value, freeBytes: free.uint64Value)
        } catch {
            reportDiskCapacityError(error.localizedDescription)
            return nil
        }
    }

    private func reportDiskCapacityError(_ message: String) {
        guard !reportedDiskCapacityError else { return }
        reportedDiskCapacityError = true
        fputs("KillSwitch disk capacity sampling failed: \(message)\n", stderr)
    }

    private func makeDiskSummary(
        now: Date,
        counters: DiskCounters,
        capacity: DiskCapacity?
    ) -> DiskResourceSummary {
        defer { previousDisk = (now, counters) }
        guard let previousDisk else {
            return DiskResourceSummary(
                capacity: capacity,
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
            capacity: capacity,
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

    private func systemCPUTicks() -> SystemCPUTicks? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        return SystemCPUTicks(
            user: UInt64(load.cpu_ticks.0),
            nice: UInt64(load.cpu_ticks.3),
            system: UInt64(load.cpu_ticks.1),
            idle: UInt64(load.cpu_ticks.2)
        )
    }

    private func taskSummary() -> (taskCount: Int, threadCount: Int) {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var setName: processor_set_name_t = 0
        guard processor_set_default(host, &setName) == KERN_SUCCESS else { return (0, 0) }
        defer { mach_port_deallocate(mach_task_self_, setName) }

        var info = processor_set_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<processor_set_load_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                processor_set_statistics(setName, PROCESSOR_SET_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Int(info.task_count), Int(info.thread_count))
    }

    private func listPIDs() -> [Int32] {
        let estimatedCount = max(256, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [Int32](repeating: 0, count: estimatedCount)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }

    private func processBSDInfo(pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        return size == MemoryLayout<proc_bsdinfo>.size ? info : nil
    }

    private func sampleLifetimeIdentities() -> [Int32: ResourceProcessIdentity] {
        var result: [Int32: ResourceProcessIdentity] = [:]
        for pid in listPIDs() {
            guard let identity = ProcessLifetimeReader.read(pid: pid, bootSession: bootSession) else { continue }
            result[pid] = identity
        }
        return result
    }

    private func processUsage(pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }

    private func processTaskInfo(pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(MemoryLayout<proc_taskinfo>.size))
        }
        return size == MemoryLayout<proc_taskinfo>.size ? info : nil
    }

    private func metadata(
        pid: Int32,
        identity: ResourceProcessIdentity,
        bsd: proc_bsdinfo,
        applicationName: String?
    ) -> ProcessMetadata {
        if let existing = metadata[identity] {
            return ProcessMetadata(name: applicationName ?? existing.name, kind: existing.kind)
        }

        var mutableBSD = bsd
        let bsdName = string(from: &mutableBSD.pbi_name)
        let command = string(from: &mutableBSD.pbi_comm)
        let pathName = processPath(pid: pid).map { URL(fileURLWithPath: $0).lastPathComponent }
        let value = ProcessMetadata(
            name: applicationName ?? pathName ?? (bsdName.isEmpty ? command : bsdName),
            kind: processKind(pid: pid)
        )
        metadata[identity] = value
        return value
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
        let size = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDARCHINFO, 0, $0, Int32(MemoryLayout<proc_archinfo>.size))
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

    private func username(for uid: uid_t) -> String {
        if let cached = usernames[uid] { return cached }
        guard let record = getpwuid(uid), let name = record.pointee.pw_name else {
            return String(uid)
        }
        let value = String(cString: name)
        usernames[uid] = value
        return value
    }

    private func string<T>(from value: inout T) -> String {
        withUnsafePointer(to: &value) { pointer in
            let bytes = UnsafeRawBufferPointer(start: pointer, count: MemoryLayout<T>.size)
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private func rate(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed >= 0.1, elapsed <= 30, current >= previous else { return nil }
        return Double(current - previous) / elapsed
    }

    private static func bootSessionIdentifier() -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        var size = buffer.count
        if sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 {
            return String(cString: buffer)
        }
        fputs("KillSwitch could not read the boot identity; process history will use a new session identity.\n", stderr)
        return UUID().uuidString
    }

    private func commandError(_ result: CommandResult, name: String) -> Error {
        let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return NSError(
            domain: "KillSwitch.ResourceSampler",
            code: Int(result.status),
            userInfo: [
                NSLocalizedDescriptionKey: detail.isEmpty
                    ? "The \(name) exited with status \(result.status)."
                    : detail
            ]
        )
    }

    private func parseError(_ message: String) -> Error {
        NSError(
            domain: "KillSwitch.ResourceSampler",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
