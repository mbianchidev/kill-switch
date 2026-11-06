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
        guard let terminatedAt else { return false }
        return now.timeIntervalSince(terminatedAt) >= ActivityProcessCatalog.terminatedRetention
            || lastSeen < now.addingTimeInterval(-ActivityHistoryStore.retention)
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
    public var pendingTerminationRecords: [ActivityProcessRecord] {
        pending.values.filter { $0.terminatedAt != nil }
    }

    public mutating func restore(_ saved: [ActivityProcessRecord]) {
        for record in saved {
            let identity = record.process.id
            guard records[identity] == nil, pending[identity] == nil else { continue }
            records[identity] = record
            if record.terminatedAt == nil { restored.insert(identity) }
        }
    }

    public mutating func observe(_ processes: [ActivityProcessDescriptor], now: Date) {
        observe(processes, inventory: ActivityProcessInventory(processes: processes), now: now)
    }

    public mutating func observe(
        _ processes: [ActivityProcessDescriptor], inventory: ActivityProcessInventory, now: Date
    ) {
        let observedIdentities = Set(processes.map(\.id))
        for identity in Array(records.keys) {
            guard let record = records[identity] else { continue }
            switch inventory[identity.pid] {
            case .present(let current) where current == identity:
                if !observedIdentities.contains(identity) {
                    update(ActivityProcessRecord(process: record.process, lastSeen: now))
                }
            case .present, .absent, .defunct:
                if record.terminatedAt == nil {
                    // Only verified exits can reconcile a lifetime last seen before app downtime.
                    update(ActivityProcessRecord(
                        process: record.process, lastSeen: record.lastSeen,
                        terminatedAt: restored.contains(identity) ? record.lastSeen : now
                    ))
                }
            case .unavailable:
                continue
            }
            restored.remove(identity)
        }
        for process in processes where inventory[process.id.pid] == .present(process.id) {
            update(ActivityProcessRecord(process: process, lastSeen: now))
            restored.remove(process.id)
        }
        prune(now: now)
    }

    public mutating func prune(now: Date) {
        for identity in Array(records.keys) {
            guard records[identity]?.isExpired(now: now) == true else { continue }
            records.removeValue(forKey: identity)
            restored.remove(identity)
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

    public mutating func markPersisted(_ persistedRecords: [ActivityProcessRecord]) {
        for record in persistedRecords where pending[record.process.id] == record {
            pending.removeValue(forKey: record.process.id)
        }
        needsPruning = false
    }

    private mutating func update(_ record: ActivityProcessRecord) {
        records[record.process.id] = record
        pending[record.process.id] = record
    }
}
