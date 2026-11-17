import Darwin
import Foundation
import IOKit
import SystemConfiguration

public struct SystemDisplay: Identifiable, Equatable, Sendable {
    public var id: String { "\(name)/\(index)" }

    public let index: Int
    public let name: String
    /// Point resolution and refresh rate, for example `1728 x 1117 @ 120.00Hz`.
    public let resolution: String?
    public let pixels: String?
    public let isMain: Bool
    public let isBuiltIn: Bool

    public init(index: Int, name: String, resolution: String?, pixels: String?, isMain: Bool, isBuiltIn: Bool) {
        self.index = index
        self.name = name
        self.resolution = resolution
        self.pixels = pixels
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
    }
}

public struct SystemVolume: Identifiable, Equatable, Sendable {
    public var id: String { path }

    public let name: String
    public let path: String
    public let format: String?
    public let totalBytes: UInt64?
    public let availableBytes: UInt64?
    public let isInternal: Bool?
    public let isRemovable: Bool?

    public init(
        name: String, path: String, format: String?, totalBytes: UInt64?,
        availableBytes: UInt64?, isInternal: Bool?, isRemovable: Bool?
    ) {
        self.name = name
        self.path = path
        self.format = format
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isInternal = isInternal
        self.isRemovable = isRemovable
    }

    public var usedBytes: UInt64? {
        guard let totalBytes, let availableBytes, totalBytes >= availableBytes else { return nil }
        return totalBytes - availableBytes
    }

    /// The used share of the volume from 0 to 1, or nil when the capacity is unknown.
    public var usedFraction: Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return Double(usedBytes) / Double(totalBytes)
    }
}

public struct SystemProfilerHardware: Equatable, Sendable {
    public let modelName: String?
    public let modelIdentifier: String?
    public let modelNumber: String?
    public let displays: [SystemDisplay]

    public init(modelName: String?, modelIdentifier: String?, modelNumber: String?, displays: [SystemDisplay]) {
        self.modelName = modelName
        self.modelIdentifier = modelIdentifier
        self.modelNumber = modelNumber
        self.displays = displays
    }
}

public struct SystemIdentity: Equatable, Sendable {
    public let computerName: String?
    public let localHostName: String?
    public let bootTime: Date?
    public let serialNumber: String?
    public let hardwareUUID: String?
    public let warnings: [String]

    public init(
        computerName: String?, localHostName: String?, bootTime: Date?,
        serialNumber: String?, hardwareUUID: String?, warnings: [String]
    ) {
        self.computerName = computerName
        self.localHostName = localHostName
        self.bootTime = bootTime
        self.serialNumber = serialNumber
        self.hardwareUUID = hardwareUUID
        self.warnings = warnings
    }
}

public enum SystemDetailsParser {
    public static let profilerArguments = ["-json", "-detailLevel", "mini", "SPHardwareDataType", "SPDisplaysDataType"]

    /// Parses `system_profiler -json` output. Missing sections or fields stay nil.
    public static func parseProfiler(_ data: Data) throws -> SystemProfilerHardware {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SystemHealthError(message: "system_profiler did not return a JSON object.")
        }
        let hardware = (root["SPHardwareDataType"] as? [[String: Any]])?.first ?? [:]
        func value(_ key: String) -> String? {
            (hardware[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        var displays: [SystemDisplay] = []
        for adapter in root["SPDisplaysDataType"] as? [[String: Any]] ?? [] {
            for screen in adapter["spdisplays_ndrvs"] as? [[String: Any]] ?? [] {
                guard (screen["spdisplays_online"] as? String) != "spdisplays_no" else { continue }
                displays.append(SystemDisplay(
                    index: displays.count,
                    name: screen["_name"] as? String ?? "Display",
                    resolution: screen["_spdisplays_resolution"] as? String,
                    pixels: screen["_spdisplays_pixels"] as? String,
                    isMain: (screen["spdisplays_main"] as? String) == "spdisplays_yes",
                    isBuiltIn: (screen["spdisplays_connection_type"] as? String) == "spdisplays_internal"
                ))
            }
        }
        return SystemProfilerHardware(
            modelName: value("machine_name"), modelIdentifier: value("machine_model"),
            modelNumber: value("model_number"), displays: displays
        )
    }

    /// Converts `kern.boottime` to a date; a zero or negative time is unavailable.
    public static func bootTime(seconds: Int, microseconds: Int32) -> Date? {
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(microseconds) / 1_000_000)
    }
}

public enum SystemDetailsReader {
    /// Reads names, boot time, and hardware identifiers with public, unprivileged interfaces.
    public static func identity() -> SystemIdentity {
        var warnings: [String] = []
        let computerName = SCDynamicStoreCopyComputerName(nil, nil) as String?
        let localHostName = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
        if computerName == nil { warnings.append("The computer name could not be read.") }

        var bootTime: Date?
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0, size == MemoryLayout<timeval>.size {
            bootTime = SystemDetailsParser.bootTime(seconds: value.tv_sec, microseconds: value.tv_usec)
        }
        if bootTime == nil { warnings.append("The boot time could not be read.") }

        let platform = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if platform != 0 { IOObjectRelease(platform) } }
        func property(_ key: String) -> String? {
            guard platform != 0 else { return nil }
            return IORegistryEntryCreateCFProperty(platform, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
        }
        let serial = property(kIOPlatformSerialNumberKey)
        let uuid = property(kIOPlatformUUIDKey)
        if serial == nil || uuid == nil { warnings.append("Hardware identifiers could not be read from IOKit.") }
        return SystemIdentity(
            computerName: computerName, localHostName: localHostName, bootTime: bootTime,
            serialNumber: serial, hardwareUUID: uuid, warnings: warnings
        )
    }

    private static let volumeKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey
    ]

    /// Lists visible mounted volumes with their capacity and space available for important data.
    public static func volumes(fileManager: FileManager = .default) -> [SystemVolume] {
        let urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: volumeKeys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in volume(at: url).flatMap { $0.browsable ? $0.volume : nil } }
            .sorted { $0.path == "/" || ($1.path != "/" && $0.name.localizedStandardCompare($1.name) == .orderedAscending) }
    }

    /// The startup volume's capacity, read without listing every mounted volume. Available space
    /// includes purgeable space, as Finder reports it.
    public static func startupVolume() -> SystemVolume? {
        volume(at: URL(fileURLWithPath: "/"))?.volume
    }

    private static func volume(at url: URL) -> (volume: SystemVolume, browsable: Bool)? {
        guard let values = try? url.resourceValues(forKeys: Set(volumeKeys)) else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage.flatMap { $0 >= 0 ? UInt64($0) : nil }
        let volume = SystemVolume(
            name: values.volumeName ?? url.lastPathComponent, path: url.path,
            format: values.volumeLocalizedFormatDescription,
            totalBytes: values.volumeTotalCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil },
            availableBytes: important ?? values.volumeAvailableCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil },
            isInternal: values.volumeIsInternal, isRemovable: values.volumeIsRemovable
        )
        return (volume, values.volumeIsBrowsable != false)
    }
}
