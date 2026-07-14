import AppKit
import Foundation

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
