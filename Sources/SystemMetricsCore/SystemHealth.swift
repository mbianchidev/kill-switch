import Darwin
import Foundation
import IOKit
import IOKit.ps

public struct SystemBatteryReading: Equatable, Sendable {
    public let chargePercent: Int?
    public let isCharging: Bool?
    public let isFullyCharged: Bool?
    public let minutesToEmpty: Int?
    public let minutesToFull: Int?
    public let cycleCount: Int?
    public let condition: String?

    public init(
        currentCapacity: Int?, maximumCapacity: Int?, isCharging: Bool?, isFullyCharged: Bool?,
        minutesToEmpty: Int?, minutesToFull: Int?, cycleCount: Int?, condition: String?
    ) {
        chargePercent = Self.chargePercentage(current: currentCapacity, maximum: maximumCapacity)
        self.isCharging = isCharging
        self.isFullyCharged = isFullyCharged
        self.minutesToEmpty = isCharging == true ? nil : minutesToEmpty.flatMap { $0 > 0 ? $0 : nil }
        self.minutesToFull = isFullyCharged == true || isCharging == false
            ? nil : minutesToFull.flatMap { $0 > 0 ? $0 : nil }
        self.cycleCount = cycleCount.flatMap { $0 >= 0 ? $0 : nil }
        let trimmed = condition?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.condition = trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func chargePercentage(current: Int?, maximum: Int?) -> Int? {
        guard let current, let maximum, maximum > 0, current >= 0, current <= maximum else { return nil }
        return Int((Double(current) / Double(maximum) * 100).rounded())
    }
}

public enum SystemBatteryState: Equatable, Sendable {
    case absent
    case available(SystemBatteryReading)
    case unavailable(String)
}

public enum SystemPowerSource: String, Sendable {
    case mains = "AC power"
    case battery = "Battery"
    case ups = "UPS"
    case unavailable = "Unavailable"
}

public enum SystemThermalState: String, CaseIterable, Sendable {
    case nominal = "Normal"
    case fair = "Warm"
    case serious = "High"
    case critical = "Critical"
    case unavailable = "Unavailable"

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unavailable
        }
    }

    public var detail: String {
        switch self {
        case .nominal: return "macOS is not reporting thermal pressure."
        case .fair: return "macOS reports elevated thermal pressure. Performance may be limited."
        case .serious: return "High thermal pressure can reduce performance. Reduce demanding workloads."
        case .critical: return "Critical thermal pressure. Reduce demanding workloads and check ventilation."
        case .unavailable: return "macOS did not expose a recognized thermal state."
        }
    }
}

public struct SystemHardwareInfo: Equatable, Sendable {
    public let model: String
    public let cpuName: String
    public let architecture: String
    public let physicalCPUCount: Int
    public let logicalCPUCount: Int
    public let activeCPUCount: Int
    public let physicalMemoryBytes: UInt64
    public let operatingSystem: String
    public let kernelVersion: String

    public init(
        model: String, cpuName: String, architecture: String, physicalCPUCount: Int,
        logicalCPUCount: Int, activeCPUCount: Int, physicalMemoryBytes: UInt64,
        operatingSystem: String, kernelVersion: String
    ) {
        self.model = model
        self.cpuName = cpuName
        self.architecture = architecture
        self.physicalCPUCount = physicalCPUCount
        self.logicalCPUCount = logicalCPUCount
        self.activeCPUCount = activeCPUCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.operatingSystem = operatingSystem
        self.kernelVersion = kernelVersion
    }
}

public struct SystemHealthSnapshot: Equatable, Sendable {
    public let date: Date
    public let thermalState: SystemThermalState
    public let lowPowerMode: Bool
    public let uptime: TimeInterval
    public let loadAverages: [Double]?
    public let powerSource: SystemPowerSource
    public let battery: SystemBatteryState
    public let warnings: [String]

    public init(
        date: Date, thermalState: SystemThermalState, lowPowerMode: Bool, uptime: TimeInterval,
        loadAverages: [Double]?, powerSource: SystemPowerSource, battery: SystemBatteryState, warnings: [String]
    ) {
        self.date = date
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
        self.uptime = uptime
        self.loadAverages = loadAverages
        self.powerSource = powerSource
        self.battery = battery
        self.warnings = warnings
    }
}

public enum SystemHealthReader {
    public static func hardware() throws -> SystemHardwareInfo {
#if arch(arm64)
        let architecture = "Apple Silicon"
#else
        let architecture = "Intel"
#endif
        return SystemHardwareInfo(
            model: try string("hw.model"), cpuName: try string("machdep.cpu.brand_string"),
            architecture: architecture, physicalCPUCount: try integer("hw.physicalcpu"),
            logicalCPUCount: ProcessInfo.processInfo.processorCount,
            activeCPUCount: ProcessInfo.processInfo.activeProcessorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            kernelVersion: try string("kern.osrelease")
        )
    }

    public static func sample() -> SystemHealthSnapshot {
        var warnings: [String] = []
        var averages = [Double](repeating: 0, count: 3)
        let load = getloadavg(&averages, 3)
        if load != 3 { warnings.append("macOS did not provide all three load averages.") }
        let power: (SystemPowerSource, SystemBatteryState)
        do {
            power = try battery()
            if case .available(let reading) = power.1, reading.chargePercent == nil {
                warnings.append("macOS did not provide a valid battery charge reading.")
            }
        } catch {
            let message = error.localizedDescription
            power = (.unavailable, .unavailable(message))
            warnings.append(message)
        }
        return SystemHealthSnapshot(
            date: Date(), thermalState: SystemThermalState(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            uptime: ProcessInfo.processInfo.systemUptime, loadAverages: load == 3 ? averages : nil,
            powerSource: power.0, battery: power.1, warnings: warnings
        )
    }

    public static func battery() throws -> (SystemPowerSource, SystemBatteryState) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            throw SystemHealthError(message: "macOS power-source information is unavailable.")
        }
        let descriptions = try (list as [CFTypeRef]).map { entry -> [String: Any] in
            guard let description = IOPSGetPowerSourceDescription(info, entry)?.takeUnretainedValue()
                    as? [String: Any] else {
                throw SystemHealthError(message: "macOS returned an unreadable power-source description.")
            }
            return description
        }
        let hasInternalBattery = descriptions.contains {
            $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType && $0[kIOPSIsPresentKey] as? Bool == true
        }
        return try decodePowerSources(
            type: type as String, descriptions: descriptions, cycleCount: hasInternalBattery ? batteryCycleCount() : nil
        )
    }

    public static func decodePowerSources(
        type: String?, descriptions: [[String: Any]], cycleCount: Int?
    ) throws -> (SystemPowerSource, SystemBatteryState) {
        let source: SystemPowerSource
        switch type {
        case kIOPMACPowerKey: source = .mains
        case kIOPMBatteryPowerKey: source = .battery
        case kIOPMUPSPowerKey: source = .ups
        default: throw SystemHealthError(message: "macOS did not provide a recognized power source.")
        }
        for description in descriptions {
            guard let kind = description[kIOPSTypeKey] as? String else {
                throw SystemHealthError(message: "macOS did not provide the power-source type.")
            }
            guard kind == kIOPSInternalBatteryType else { continue }
            guard let present = description[kIOPSIsPresentKey] as? Bool else {
                throw SystemHealthError(message: "macOS did not verify whether the internal battery is present.")
            }
            guard present else { continue }
            return (source, .available(SystemBatteryReading(
                currentCapacity: description[kIOPSCurrentCapacityKey] as? Int,
                maximumCapacity: description[kIOPSMaxCapacityKey] as? Int,
                isCharging: description[kIOPSIsChargingKey] as? Bool,
                isFullyCharged: description[kIOPSIsChargedKey] as? Bool,
                minutesToEmpty: description[kIOPSTimeToEmptyKey] as? Int,
                minutesToFull: description[kIOPSTimeToFullChargeKey] as? Int,
                cycleCount: cycleCount, condition: description[kIOPSBatteryHealthConditionKey] as? String
                    ?? description[kIOPSBatteryHealthKey] as? String
            )))
        }
        return (source, .absent)
    }

    private static func batteryCycleCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(
            service, "CycleCount" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber)?.intValue
    }

    private static func string(_ name: String) throws -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else {
            throw SystemHealthError(message: "Cannot read \(name): \(String(cString: strerror(errno))).")
        }
        guard (1...16_384).contains(size) else {
            throw SystemHealthError(message: "macOS returned an invalid \(name) response size.")
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
            throw SystemHealthError(message: "Cannot read \(name): \(String(cString: strerror(errno))).")
        }
        guard size > 0, size <= bytes.count, bytes.prefix(size).contains(0),
              let value = String(bytes: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8),
              !value.isEmpty else {
            throw SystemHealthError(message: "macOS returned an unreadable \(name) value.")
        }
        return value
    }

    private static func integer(_ name: String) throws -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size, value > 0 else {
            throw SystemHealthError(message: "macOS did not provide a valid \(name) value.")
        }
        return Int(value)
    }
}

public struct SystemHealthError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}
