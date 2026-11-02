import Foundation

public struct ProcessEnergyCache: Sendable {
    private var powerByIdentity: [ActivityProcessIdentity: Double] = [:]
    private var sleepByIdentity: [ActivityProcessIdentity: Bool] = [:]
    private var powerFailure: String?
    private var sleepFailure: String?

    public init() {}

    public mutating func updatePower(
        _ readings: [Int32: Double], identities: [Int32: ActivityProcessIdentity]
    ) {
        powerByIdentity.removeAll(keepingCapacity: true)
        powerFailure = nil
        for (pid, value) in readings where value.isFinite && value >= 0 {
            if let identity = identities[pid] { powerByIdentity[identity] = value }
        }
    }

    public mutating func updateSleepAssertions(
        _ preventingPIDs: Set<Int32>, identities: [Int32: ActivityProcessIdentity]
    ) {
        sleepByIdentity.removeAll(keepingCapacity: true)
        sleepFailure = nil
        for identity in identities.values {
            sleepByIdentity[identity] = preventingPIDs.contains(identity.pid)
        }
    }

    public mutating func failPower(_ message: String) {
        powerByIdentity.removeAll(keepingCapacity: true)
        powerFailure = message
    }

    public mutating func failSleepAssertions(_ message: String) {
        sleepByIdentity.removeAll(keepingCapacity: true)
        sleepFailure = message
    }

    public var warnings: [String] {
        [powerFailure.map { "Energy: \($0)" }, sleepFailure.map { "Sleep assertions: \($0)" }].compactMap { $0 }
    }

    // A mode change invalidates readings, not unresolved collector failures.
    public mutating func clearMeasurements() {
        powerByIdentity.removeAll(keepingCapacity: true)
        sleepByIdentity.removeAll(keepingCapacity: true)
    }

    public func power(for identity: ActivityProcessIdentity?) -> Double? {
        identity.flatMap { powerByIdentity[$0] }
    }

    public func preventsSleep(for identity: ActivityProcessIdentity?) -> Bool? {
        identity.flatMap { sleepByIdentity[$0] }
    }

    public static func totalPower(_ measurements: [Double?]) -> Double? {
        let available = measurements.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
        guard !available.isEmpty else { return nil }
        let total = available.reduce(0, +)
        return total.isFinite ? total : nil
    }
}
