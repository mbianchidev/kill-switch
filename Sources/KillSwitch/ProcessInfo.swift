import Foundation

struct ProcessEntry: Identifiable, Equatable {
    let id: Int32
    let pid: Int32
    let name: String
    let cpu: Double
    let memory: Double // in MB

    init(pid: Int32, name: String, cpu: Double, memory: Double) {
        self.id = pid
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memory = memory
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
    private let username = "mbianchidev"

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

    private func fetchProcesses() -> [ProcessEntry] {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-u", username, "-o", "pid,pcpu,rss,comm", "-r"]

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

        var entries: [ProcessEntry] = []
        let lines = output.components(separatedBy: "\n").dropFirst() // skip header

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let parts = trimmed.split(maxSplits: 3, omittingEmptySubsequences: true) { $0.isWhitespace }
            guard parts.count >= 4 else { continue }

            guard let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let rssKB = Double(parts[2]) else { continue }

            let name = String(parts[3]).components(separatedBy: "/").last ?? String(parts[3])
            let memoryMB = rssKB / 1024.0

            entries.append(ProcessEntry(pid: pid, name: name, cpu: cpu, memory: memoryMB))
        }

        return entries
    }
}
