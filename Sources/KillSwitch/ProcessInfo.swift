import Foundation
import AppKit

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
            let entries = ProcessSampler.fetchCollapsed(user: self.username)
            DispatchQueue.main.async {
                self.processes = entries
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
