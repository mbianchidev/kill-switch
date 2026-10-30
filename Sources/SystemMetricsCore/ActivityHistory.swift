import Foundation

public struct ActivityProcessIdentity: Hashable, Codable, Sendable {
    public let bootSession: String
    public let pid: Int32
    public let startTime: UInt64

    public var key: String { "\(bootSession)/\(pid)/\(startTime)" }

    public init(bootSession: String, pid: Int32, startTime: UInt64) {
        self.bootSession = bootSession
        self.pid = pid
        self.startTime = startTime
    }

    public static func verified(
        pid: Int32, before: [Int32: Self], after: [Int32: Self], current: Self?
    ) -> Self? {
        guard let original = before[pid], after[pid] == original, current == original else { return nil }
        return original
    }
}

public struct ActivityProcessDescriptor: Identifiable, Equatable, Sendable {
    public let identity: ActivityProcessIdentity
    public let name: String
    public let user: String
    public var id: ActivityProcessIdentity { identity }

    public init(identity: ActivityProcessIdentity, name: String, user: String) {
        self.identity = identity
        self.name = name
        self.user = user
    }
}

public struct ActivityValues: Equatable, Sendable {
    public var cpu: Double?
    public var memory: Double?
    public var diskRead: Double?
    public var diskWritten: Double?
    public var received: Double?
    public var sent: Double?
    public var cpuSystem: Double?
    public var cpuUser: Double?

    public init(
        cpu: Double? = nil, memory: Double? = nil,
        diskRead: Double? = nil, diskWritten: Double? = nil,
        received: Double? = nil, sent: Double? = nil,
        cpuSystem: Double? = nil, cpuUser: Double? = nil
    ) {
        func valid(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        self.cpu = valid(cpu)
        self.memory = valid(memory)
        self.diskRead = valid(diskRead)
        self.diskWritten = valid(diskWritten)
        self.received = valid(received)
        self.sent = valid(sent)
        self.cpuSystem = valid(cpuSystem)
        self.cpuUser = valid(cpuUser)
    }

    var components: [Double?] { [cpu, memory, diskRead, diskWritten, received, sent, cpuSystem, cpuUser] }

    init(components: [Double?]) {
        self.init(
            cpu: components[0], memory: components[1],
            diskRead: components[2], diskWritten: components[3],
            received: components[4], sent: components[5], cpuSystem: components[6], cpuUser: components[7]
        )
    }

    public func pair(for metric: ResourceMetricKind) -> (Double?, Double?) {
        switch metric {
        case .cpu: return (cpu, nil)
        case .memory: return (memory, nil)
        case .disk: return (diskRead, diskWritten)
        case .network: return (received, sent)
        case .energy: return (nil, nil)
        }
    }
}

public struct ActivityProcessSample: Identifiable, Equatable, Sendable {
    public let process: ActivityProcessDescriptor
    public let values: ActivityValues
    public var id: ActivityProcessIdentity { process.identity }

    public init(process: ActivityProcessDescriptor, values: ActivityValues) {
        self.process = process
        self.values = values
    }
}

public struct ActivitySnapshot: Equatable, Sendable {
    public let date: Date
    public let system: ActivityValues
    public let processes: [ActivityProcessSample]

    public init(date: Date, system: ActivityValues, processes: [ActivityProcessSample]) {
        self.date = date
        self.system = system
        self.processes = processes
    }

    public func point(for identity: ActivityProcessIdentity?) -> ActivityHistoryPoint {
        ActivityHistoryPoint(
            date: date,
            values: identity.map { id in
                processes.first { $0.process.identity == id }?.values ?? ActivityValues()
            } ?? system
        )
    }
}

public struct ActivityHistoryPoint: Identifiable, Equatable, Sendable {
    public let date: Date
    public let values: ActivityValues
    public var id: Date { date }

    public init(date: Date, values: ActivityValues) {
        self.date = date
        self.values = values
    }
}

public enum ActivityHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case live = "Live · 5m"
    case hour = "1 hour"
    case sixHours = "6 hours"
    case day = "24 hours"

    public var id: Self { self }
    public var seconds: TimeInterval {
        switch self {
        case .live: return 300
        case .hour: return 3_600
        case .sixHours: return 21_600
        case .day: return 86_400
        }
    }
}

public struct ActivitySeriesPoint: Identifiable, Sendable {
    public let date: Date
    public let value: Double
    public let lowerBound: Double
    public let secondary: Bool
    public let segment: Int
    public var id: String { "\(date.timeIntervalSince1970)/\(secondary)" }
}

public enum ActivitySeries {
    public static func points(
        _ history: [ActivityHistoryPoint], metric: ResourceMetricKind, splitCPU: Bool = false
    ) -> [ActivitySeriesPoint] {
        var result: [ActivitySeriesPoint] = []
        for secondary in [false, true] {
            var segment = 0
            var previous: Date?
            for point in history {
                let pair: (Double?, Double?)
                if splitCPU && metric == .cpu {
                    if let system = point.values.cpuSystem, let user = point.values.cpuUser { pair = (system, user) }
                    else { pair = (nil, nil) }
                } else { pair = point.values.pair(for: metric) }
                guard let value = secondary ? pair.1 : pair.0 else {
                    segment += 1
                    previous = nil
                    continue
                }
                let baseline = splitCPU && metric == .cpu && secondary ? (pair.0 ?? 0) : 0
                if let previous, point.date.timeIntervalSince(previous) > 90 {
                    segment += 1
                }
                result.append(ActivitySeriesPoint(
                    date: point.date, value: value + baseline, lowerBound: baseline,
                    secondary: secondary, segment: segment
                ))
                previous = point.date
            }
        }
        return result
    }
}

public struct ActivityRateTracker {
    private struct Counters {
        let dates: [Date]
        let values: [UInt64?]
    }
    private var previous: [ActivityProcessIdentity: Counters] = [:]

    public init() {}

    public mutating func sample(
        identity: ActivityProcessIdentity, date: Date,
        diskRead: UInt64?, diskWritten: UInt64?, received: UInt64?, sent: UInt64?,
        diskDate: Date? = nil, networkDate: Date? = nil
    ) -> ActivityValues {
        let values = [diskRead, diskWritten, received, sent]
        let dates = [diskDate ?? date, diskDate ?? date, networkDate ?? date, networkDate ?? date]
        defer { previous[identity] = Counters(dates: dates, values: values) }
        guard let old = previous[identity] else { return ActivityValues() }
        let rates = values.indices.map { index -> Double? in
            let elapsed = dates[index].timeIntervalSince(old.dates[index])
            guard elapsed >= 0.1, elapsed <= 30,
                  let current = values[index], let previous = old.values[index],
                  current >= previous else { return nil }
            return Double(current - previous) / elapsed
        }
        return ActivityValues(
            diskRead: rates[0], diskWritten: rates[1], received: rates[2], sent: rates[3]
        )
    }

    public mutating func retain(_ identities: Set<ActivityProcessIdentity>) {
        previous = previous.filter { identities.contains($0.key) }
    }
}

public struct ActivityAccumulator {
    private struct Average {
        var totals = [Double](repeating: 0, count: 8)
        var counts = [Int](repeating: 0, count: 8)

        mutating func append(_ values: ActivityValues) {
            for (index, value) in values.components.enumerated() {
                guard let value else { continue }
                totals[index] += value
                counts[index] += 1
            }
        }

        var values: ActivityValues {
            ActivityValues(components: totals.indices.map {
                counts[$0] == 0 ? nil : totals[$0] / Double(counts[$0])
            })
        }
    }

    private var minute: Date?
    private var lastDate: Date?
    private var system = Average()
    private var processes: [ActivityProcessIdentity: (ActivityProcessDescriptor, Average)] = [:]
    public init() {}

    public var current: ActivitySnapshot? {
        lastDate.map { date in
            ActivitySnapshot(
                date: date, system: system.values,
                processes: processes.values.map { ActivityProcessSample(process: $0.0, values: $0.1.values) }
            )
        }
    }

    public mutating func append(_ snapshot: ActivitySnapshot) -> ActivitySnapshot? {
        let bucket = Date(timeIntervalSince1970: floor(snapshot.date.timeIntervalSince1970 / 60) * 60)
        let completed = minute != nil && minute != bucket ? current : nil
        if minute != bucket {
            minute = bucket
            system = Average()
            processes.removeAll(keepingCapacity: true)
        }
        lastDate = snapshot.date
        system.append(snapshot.system)
        for sample in snapshot.processes {
            var entry = processes[sample.process.identity] ?? (sample.process, Average())
            entry.1.append(sample.values)
            processes[sample.process.identity] = entry
        }
        return completed
    }
}

public struct ActivityWriteBuffer {
    private struct Entry {
        let snapshot: ActivitySnapshot
        let queuedAt: Date
    }
    private var entries: [Entry] = []
    public var count: Int { entries.count }
    public init() {}

    @discardableResult
    public mutating func append(_ snapshot: ActivitySnapshot, now: Date) -> Int {
        let queuedAt = entries.first { $0.snapshot.date == snapshot.date }?.queuedAt ?? now
        entries.removeAll { $0.snapshot.date == snapshot.date }
        entries.append(Entry(snapshot: snapshot, queuedAt: queuedAt))
        entries.sort { $0.snapshot.date < $1.snapshot.date }
        let previousCount = entries.count
        let cutoff = now.addingTimeInterval(-300)
        entries.removeAll { $0.queuedAt < cutoff }
        if entries.count > 6 { entries.removeFirst(entries.count - 6) }
        return previousCount - entries.count
    }

    public mutating func flush(save: (ActivitySnapshot) throws -> Void) throws {
        while let entry = entries.first {
            try save(entry.snapshot)
            entries.removeFirst()
        }
    }
}
