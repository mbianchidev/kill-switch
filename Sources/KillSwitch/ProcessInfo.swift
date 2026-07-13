import Foundation
import AppKit
import Darwin
import os

struct ProcessEntry: Identifiable, Equatable {
    let id: Int32
    let pid: Int32
    let name: String
    let cpu: Double
    let memory: Double // in MB
    let power: Double // energy impact (macOS POWER metric), 0 when not sampled
    let icon: NSImage?

    init(pid: Int32, name: String, cpu: Double, memory: Double, power: Double = 0, icon: NSImage? = nil) {
        self.id = pid
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memory = memory
        self.power = power
        self.icon = icon
    }

    static func == (lhs: ProcessEntry, rhs: ProcessEntry) -> Bool {
        lhs.pid == rhs.pid &&
        lhs.name == rhs.name &&
        lhs.cpu == rhs.cpu &&
        lhs.memory == rhs.memory &&
        lhs.power == rhs.power &&
        lhs.icon === rhs.icon
    }
}

enum SortOption: String, CaseIterable {
    case cpu = "CPU Usage"
    case memory = "Memory"
    case name = "Name"
    case pid = "PID"
}

struct SystemResourceSnapshot: Equatable {
    let freeMemoryMB: Double?
    let freeCPUCount: Double?
    let totalCPUCount: Int

    static let unavailable = SystemResourceSnapshot(
        freeMemoryMB: nil,
        freeCPUCount: nil,
        totalCPUCount: max(1, Foundation.ProcessInfo.processInfo.activeProcessorCount)
    )
}

private final class SystemResourceSampler {
    private struct CPUTicks {
        let user: UInt32
        let system: UInt32
        let idle: UInt32
        let nice: UInt32
    }

    private let totalCPUCount = max(1, Foundation.ProcessInfo.processInfo.activeProcessorCount)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "system-resources")
    private var previousCPUTicks: CPUTicks?
    private var loggedCPUFailure = false
    private var loggedMemoryFailure = false

    init() {
        previousCPUTicks = Self.captureCPUTicks().ticks
    }

    func sample() -> SystemResourceSnapshot {
        SystemResourceSnapshot(
            freeMemoryMB: freeMemoryMB(),
            freeCPUCount: freeCPUCount(),
            totalCPUCount: totalCPUCount
        )
    }

    private func freeMemoryMB() -> Double? {
        var pageSize: vm_size_t = 0
        let pageSizeResult = host_page_size(mach_host_self(), &pageSize)
        guard pageSizeResult == KERN_SUCCESS else {
            logMemoryFailure(pageSizeResult)
            return nil
        }

        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            logMemoryFailure(result)
            return nil
        }

        loggedMemoryFailure = false
        let availablePages = UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.speculative_count)
        let availableBytes = availablePages * UInt64(pageSize)
        return Double(availableBytes) / 1_048_576
    }

    private func freeCPUCount() -> Double? {
        let capture = Self.captureCPUTicks()
        guard let current = capture.ticks else {
            logCPUFailure(capture.result)
            return nil
        }

        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks else { return nil }

        loggedCPUFailure = false
        let user = tickDelta(current.user, previous.user)
        let system = tickDelta(current.system, previous.system)
        let idle = tickDelta(current.idle, previous.idle)
        let nice = tickDelta(current.nice, previous.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }

        let idleRatio = Double(idle) / Double(total)
        return min(Double(totalCPUCount), max(0, idleRatio * Double(totalCPUCount)))
    }

    private static func captureCPUTicks() -> (ticks: CPUTicks?, result: kern_return_t) {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (nil, result) }

        return (
            CPUTicks(
                user: load.cpu_ticks.0,
                system: load.cpu_ticks.1,
                idle: load.cpu_ticks.2,
                nice: load.cpu_ticks.3
            ),
            result
        )
    }

    private func tickDelta(_ current: UInt32, _ previous: UInt32) -> UInt64 {
        UInt64(current &- previous)
    }

    private func logCPUFailure(_ result: kern_return_t) {
        guard !loggedCPUFailure else { return }
        loggedCPUFailure = true
        logger.error("CPU sampling failed with kern_return_t \(result)")
    }

    private func logMemoryFailure(_ result: kern_return_t) {
        guard !loggedMemoryFailure else { return }
        loggedMemoryFailure = true
        logger.error("Memory sampling failed with kern_return_t \(result)")
    }
}

class ProcessMonitor: ObservableObject {
    @Published var processes: [ProcessEntry] = []
    @Published var sortBy: SortOption = .cpu
    @Published var filterText: String = ""
    @Published private(set) var systemResources = SystemResourceSnapshot.unavailable

    private var timer: Timer?
    private let refreshQueue = DispatchQueue(label: "killswitch.processes.refresh", qos: .userInitiated)
    private let resourceSampler = SystemResourceSampler()
    // Resolve the user the app is running as, so it works for any account
    // rather than a single hardcoded username.
    private let username = NSUserName()

    var filteredProcesses: [ProcessEntry] {
        var result = processes
        if !filterText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(filterText) ||
                String($0.pid).contains(filterText)
            }
        }
        switch sortBy {
        case .cpu:
            result.sort { $0.cpu > $1.cpu }
        case .memory:
            result.sort { $0.memory > $1.memory }
        case .name:
            result.sort { $0.name.lowercased() < $1.name.lowercased() }
        case .pid:
            result.sort { $0.pid < $1.pid }
        }
        return result
    }

    var runningCount: Int {
        processes.count
    }

    func startMonitoring() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        refreshQueue.async { [weak self] in
            guard let self = self else { return }
            let entries = ProcessSampler.fetchCollapsed(user: self.username)
            let resources = self.resourceSampler.sample()
            DispatchQueue.main.async {
                self.processes = entries
                self.systemResources = resources
            }
        }
    }

    func killProcess(pid: Int32) {
        ProcessSampler.terminate(pid: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refresh()
        }
    }
}
