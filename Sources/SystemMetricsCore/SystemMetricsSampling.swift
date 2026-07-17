import Foundation

public enum ResourceMetricKind: String, CaseIterable, Identifiable, Sendable {
    case cpu = "CPU"
    case memory = "Memory"
    case energy = "Energy"
    case disk = "Disk"
    case network = "Network"

    public var id: Self { self }
}

public struct ResourceSamplingPolicy: Equatable, Sendable {
    public let intervalSeconds: Int
    public let usesTop: Bool
    public let collectsMemoryPressure: Bool
    public let collectsEnergyDetails: Bool
    public let collectsNetwork: Bool

    public static func forMetric(_ metric: ResourceMetricKind) -> ResourceSamplingPolicy {
        switch metric {
        case .cpu:
            return ResourceSamplingPolicy(
                intervalSeconds: 6,
                usesTop: false,
                collectsMemoryPressure: false,
                collectsEnergyDetails: false,
                collectsNetwork: false
            )
        case .memory:
            return ResourceSamplingPolicy(
                intervalSeconds: 6,
                usesTop: false,
                collectsMemoryPressure: true,
                collectsEnergyDetails: false,
                collectsNetwork: false
            )
        case .energy:
            return ResourceSamplingPolicy(
                intervalSeconds: 15,
                usesTop: true,
                collectsMemoryPressure: false,
                collectsEnergyDetails: true,
                collectsNetwork: false
            )
        case .disk:
            return ResourceSamplingPolicy(
                intervalSeconds: 6,
                usesTop: false,
                collectsMemoryPressure: false,
                collectsEnergyDetails: false,
                collectsNetwork: false
            )
        case .network:
            return ResourceSamplingPolicy(
                intervalSeconds: 6,
                usesTop: false,
                collectsMemoryPressure: false,
                collectsEnergyDetails: false,
                collectsNetwork: true
            )
        }
    }
}

public struct SystemCPUTicks: Equatable, Sendable {
    public let user: UInt64
    public let nice: UInt64
    public let system: UInt64
    public let idle: UInt64

    public init(user: UInt64, nice: UInt64, system: UInt64, idle: UInt64) {
        self.user = user
        self.nice = nice
        self.system = system
        self.idle = idle
    }
}

public struct SystemCPUUsage: Equatable, Sendable {
    public let userPercent: Double
    public let systemPercent: Double
    public let idlePercent: Double
}

public enum SystemMetricsCalculator {
    public static func systemCPUUsage(
        current: SystemCPUTicks,
        previous: SystemCPUTicks?
    ) -> SystemCPUUsage {
        let user = tickDelta(current: current.user, previous: previous?.user)
            + tickDelta(current: current.nice, previous: previous?.nice)
        let system = tickDelta(current: current.system, previous: previous?.system)
        let idle = tickDelta(current: current.idle, previous: previous?.idle)
        let total = user + system + idle

        guard total > 0 else {
            return SystemCPUUsage(userPercent: 0, systemPercent: 0, idlePercent: 0)
        }

        return SystemCPUUsage(
            userPercent: Double(user) * 100 / Double(total),
            systemPercent: Double(system) * 100 / Double(total),
            idlePercent: Double(idle) * 100 / Double(total)
        )
    }

    public static func processCPUPercent(
        currentNanoseconds: UInt64,
        previousNanoseconds: UInt64,
        elapsedSeconds: TimeInterval
    ) -> Double? {
        guard elapsedSeconds >= 0.1, currentNanoseconds >= previousNanoseconds else {
            return nil
        }

        let usedSeconds = Double(currentNanoseconds - previousNanoseconds) / 1_000_000_000
        return usedSeconds * 100 / elapsedSeconds
    }

    private static func tickDelta(current: UInt64, previous: UInt64?) -> UInt64 {
        guard let previous else { return current }
        guard current < previous else { return current - previous }

        let modulus = UInt64(UInt32.max) + 1
        return current + modulus - previous
    }
}
