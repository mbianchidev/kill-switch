import Foundation
import AppKit

struct ProcessEntry: Identifiable, Equatable {
    let id: Int32
    let pid: Int32
    let name: String
    let cpu: Double
    let memory: Double // in MB
    let icon: NSImage?

    init(pid: Int32, name: String, cpu: Double, memory: Double, icon: NSImage? = nil) {
        self.id = pid
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memory = memory
        self.icon = icon
    }

    static func == (lhs: ProcessEntry, rhs: ProcessEntry) -> Bool {
        lhs.pid == rhs.pid &&
        lhs.name == rhs.name &&
        lhs.cpu == rhs.cpu &&
        lhs.memory == rhs.memory &&
        lhs.icon === rhs.icon
    }
}

enum SortOption: String, CaseIterable {
    case cpu = "CPU Usage"
    case memory = "Memory"
    case name = "Name"
    case pid = "PID"
}

class ProcessMonitor: ObservableObject {
    @Published var processes: [ProcessEntry] = []
    @Published var sortBy: SortOption = .cpu
    @Published var filterText: String = ""
    
    private var timer: Timer?
    // Resolve the user the app is running as, so it works for any account
    // rather than a single hardcoded username.
    private let username = NSUserName()

    var filteredProcesses: [ProcessEntry] {
        var result = processes
        if !filterText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(filterText)
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let entries = self.fetchProcesses()
            DispatchQueue.main.async {
                self.processes = entries
            }
        }
    }

    func killProcess(pid: Int32) {
        let result = kill(pid, SIGTERM)
        if result != 0 {
            kill(pid, SIGKILL)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refresh()
        }
    }

    /// Raw process data as parsed from `ps`, before helper processes are
    /// collapsed into their parent.
    private struct RawProcess {
        let pid: Int32
        let ppid: Int32
        let cpu: Double
        let memory: Double
        let name: String
    }

    /// Build a map of process id -> application icon for GUI applications that
    /// are currently running, so the list can show recognizable icons.
    private func appIcons() -> [Int32: NSImage] {
        var map: [Int32: NSImage] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let icon = app.icon {
                map[app.processIdentifier] = icon
            }
        }
        return map
    }

    private func fetchProcesses() -> [ProcessEntry] {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-u", username, "-o", "pid,ppid,pcpu,rss,comm", "-r"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var raw: [Int32: RawProcess] = [:]
        let lines = output.components(separatedBy: "\n").dropFirst() // skip header

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let parts = trimmed.split(maxSplits: 4, omittingEmptySubsequences: true) { $0.isWhitespace }
            guard parts.count >= 5 else { continue }

            guard let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let cpu = Double(parts[2]),
                  let rssKB = Double(parts[3]) else { continue }

            let name = String(parts[4]).components(separatedBy: "/").last ?? String(parts[4])
            let memoryMB = rssKB / 1024.0

            raw[pid] = RawProcess(pid: pid, ppid: ppid, cpu: cpu, memory: memoryMB, name: name)
        }

        return collapse(raw)
    }

    /// Collapse helper/child processes into their top-most ancestor so that
    /// only main processes are shown. For example, Spotify spawns several
    /// helper processes, but only the parent process is listed and the
    /// helpers' CPU and memory usage are aggregated into it.
    private func collapse(_ raw: [Int32: RawProcess]) -> [ProcessEntry] {
        let icons = appIcons()

        // Find the top-most ancestor of a process that is still owned by the
        // current user. Walk up the parent chain while the parent is also a
        // listed process; the first process whose parent is not listed (its
        // parent is launchd or another owner) is treated as the main process.
        func rootPid(of pid: Int32) -> Int32 {
            var current = pid
            var visited: Set<Int32> = []
            while let proc = raw[current], raw[proc.ppid] != nil {
                if visited.contains(current) { break } // guard against cycles
                visited.insert(current)
                current = proc.ppid
            }
            return current
        }

        var aggregatedCPU: [Int32: Double] = [:]
        var aggregatedMemory: [Int32: Double] = [:]

        for (pid, proc) in raw {
            let root = rootPid(of: pid)
            aggregatedCPU[root, default: 0] += proc.cpu
            aggregatedMemory[root, default: 0] += proc.memory
        }

        var entries: [ProcessEntry] = []
        for rootPid in aggregatedCPU.keys {
            guard let proc = raw[rootPid] else { continue }
            entries.append(
                ProcessEntry(
                    pid: rootPid,
                    name: proc.name,
                    cpu: aggregatedCPU[rootPid] ?? proc.cpu,
                    memory: aggregatedMemory[rootPid] ?? proc.memory,
                    icon: icons[rootPid]
                )
            )
        }

        return entries
    }
}
