import Foundation

public struct ActivityProcessRecord: Equatable, Sendable {
    public let process: ActivityProcessDescriptor
    public let lastSeen: Date
    public let terminatedAt: Date?

    public init(process: ActivityProcessDescriptor, lastSeen: Date, terminatedAt: Date? = nil) {
        self.process = process
        self.lastSeen = lastSeen
        self.terminatedAt = terminatedAt
    }

    public func isExpired(now: Date) -> Bool {
        terminatedAt.map { now.timeIntervalSince($0) >= ActivityProcessCatalog.terminatedRetention } ?? false
    }
}

public struct ActivityProcessCatalog {
    public static let terminatedRetention: TimeInterval = 21_600
    public private(set) var records: [ActivityProcessIdentity: ActivityProcessRecord] = [:]
    public private(set) var needsPruning = false
    private var pending: [ActivityProcessIdentity: ActivityProcessRecord] = [:]
    private var restored: Set<ActivityProcessIdentity> = []

    public init() {}

    public var processes: [ActivityProcessDescriptor] { records.values.map(\.process) }
    public var pendingRecords: [ActivityProcessRecord] { Array(pending.values) }

    public mutating func restore(_ saved: [ActivityProcessRecord]) {
        for record in saved {
            let identity = record.process.id
            guard records[identity] == nil, pending[identity] == nil else { continue }
            records[identity] = record
            restored.insert(identity)
        }
    }

    public mutating func observe(_ processes: [ActivityProcessDescriptor], now: Date) {
        let identities = Set(processes.map(\.id))
        for identity in Array(records.keys) where !identities.contains(identity) {
            guard let record = records[identity], record.terminatedAt == nil else { continue }
            // An exit during downtime has no observed timestamp; use the last saved sighting.
            update(ActivityProcessRecord(
                process: record.process, lastSeen: record.lastSeen,
                terminatedAt: restored.contains(identity) ? record.lastSeen : now
            ))
        }
        for process in processes {
            update(ActivityProcessRecord(process: process, lastSeen: now))
        }
        restored.removeAll()
        prune(now: now)
    }

    public mutating func prune(now: Date) {
        for identity in Array(records.keys) {
            guard records[identity]?.isExpired(now: now) == true else { continue }
            records.removeValue(forKey: identity)
            needsPruning = true
        }
        let cutoff = now.addingTimeInterval(-ActivityHistoryStore.retention)
        // Retain expired changes for retry, but not beyond the database's own history window.
        pending = pending.filter { $0.value.lastSeen >= cutoff }
    }

    public func retainingProcesses(in snapshot: ActivitySnapshot) -> ActivitySnapshot {
        ActivitySnapshot(
            date: snapshot.date, system: snapshot.system,
            processes: snapshot.processes.filter { records[$0.id] != nil }
        )
    }

    public mutating func markPersisted() {
        pending.removeAll(keepingCapacity: true)
        needsPruning = false
    }

    private mutating func update(_ record: ActivityProcessRecord) {
        records[record.process.id] = record
        pending[record.process.id] = record
    }
}
