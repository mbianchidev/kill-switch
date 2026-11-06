public enum ProcessLifetimePresence: Equatable, Sendable {
    case present(ActivityProcessIdentity)
    case absent
    case defunct
    case unavailable

    public var identity: ActivityProcessIdentity? {
        guard case .present(let identity) = self else { return nil }
        return identity
    }
}

public struct ActivityProcessInventory: Equatable, Sendable {
    private let readings: [Int32: ProcessLifetimePresence]

    public init(_ readings: [Int32: ProcessLifetimePresence] = [:]) {
        self.readings = readings
    }

    public init(processes: [ActivityProcessDescriptor]) {
        self.readings = Dictionary(
            processes.map { ($0.id.pid, .present($0.id)) },
            uniquingKeysWith: { _, _ in .unavailable }
        )
    }

    public subscript(pid: Int32) -> ProcessLifetimePresence {
        let reading = readings[pid] ?? .unavailable
        if case .present(let identity) = reading, identity.pid != pid { return .unavailable }
        return reading
    }
}
