import Foundation

/// Threshold units use the same 1,024-based multiples as the app's size labels,
/// so a 10 GB limit matches a folder displayed as 10.00 GB.
public enum FolderSizeUnit: String, CaseIterable, Codable, Sendable {
    case megabytes = "MB"
    case gigabytes = "GB"
    case terabytes = "TB"

    public var bytes: UInt64 {
        switch self {
        case .megabytes: return 1 << 20
        case .gigabytes: return 1 << 30
        case .terabytes: return 1 << 40
        }
    }
}

public enum FolderSizeThreshold {
    public static let minimumBytes: UInt64 = FolderSizeUnit.megabytes.bytes
    public static let maximumBytes: UInt64 = 1_024 * FolderSizeUnit.terabytes.bytes
    public static let defaultBytes: UInt64 = 10 * FolderSizeUnit.gigabytes.bytes

    /// Parses a positive value such as `10`, `1.5`, or `1,5` in the given unit. At most two
    /// decimals are accepted, so a thousands separator such as `1,500` is rejected, not read as 1.5.
    public static func bytes(from text: String, unit: FolderSizeUnit) throws -> UInt64 {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.contains(where: { !$0.isEmpty }),
              parts.count == 1 || parts[1].count <= 2,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              value > 0 else {
            throw FolderSizeWatchError.invalidThreshold(
                "Enter a positive number with up to two decimals and no thousands separators, for example 10 or 1.5."
            )
        }
        var exact = value * Decimal(unit.bytes)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &exact, 0, .plain)
        guard rounded >= Decimal(minimumBytes), rounded <= Decimal(maximumBytes) else {
            throw FolderSizeWatchError.invalidThreshold(rangeDescription)
        }
        return NSDecimalNumber(decimal: rounded).uint64Value
    }

    /// Returns the largest unit whose two-decimal value parses back to exactly `bytes`,
    /// so redisplaying and resubmitting a saved limit never changes it.
    public static func components(for bytes: UInt64) -> (value: String, unit: FolderSizeUnit) {
        for unit in FolderSizeUnit.allCases.reversed() where bytes >= unit.bytes {
            let value = roundedValue(bytes, unit: unit)
            if (try? Self.bytes(from: value, unit: unit)) == bytes {
                return (value, unit)
            }
        }
        return (roundedValue(bytes, unit: .megabytes), .megabytes)
    }

    private static func roundedValue(_ bytes: UInt64, unit: FolderSizeUnit) -> String {
        var value = Decimal(bytes) / Decimal(unit.bytes)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    public static func validate(_ bytes: UInt64) throws {
        guard (minimumBytes...maximumBytes).contains(bytes) else {
            throw FolderSizeWatchError.invalidThreshold(rangeDescription)
        }
    }

    private static var rangeDescription: String {
        "Choose a limit from 1 MB through 1024 TB."
    }
}

public enum FolderSizeAlertState: Codable, Equatable, Sendable {
    /// The next measurement at or above the threshold alerts.
    case armed
    /// The folder reached its threshold; no further alert until it is re-armed.
    case reached(since: Date)
}

public struct FolderSizeWatch: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let path: String
    public fileprivate(set) var thresholdBytes: UInt64
    public fileprivate(set) var isEnabled: Bool
    public fileprivate(set) var alertState: FolderSizeAlertState

    public init(
        id: UUID = UUID(),
        path: String,
        thresholdBytes: UInt64,
        isEnabled: Bool = true,
        alertState: FolderSizeAlertState = .armed
    ) {
        self.id = id
        self.path = path
        self.thresholdBytes = thresholdBytes
        self.isEnabled = isEnabled
        self.alertState = alertState
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var name: String { path == "/" ? "/" : url.lastPathComponent }
}

public struct FolderSizeMeasurement: Equatable, Sendable {
    public let path: String
    /// Allocated bytes of readable regular files; hard-linked files count once.
    public let sizeBytes: UInt64
    public let fileCount: Int
    public let permissionDeniedCount: Int
    public let unreadableItemCount: Int
    public let measuredAt: Date

    public init(
        path: String,
        sizeBytes: UInt64,
        fileCount: Int,
        permissionDeniedCount: Int,
        unreadableItemCount: Int,
        measuredAt: Date
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.permissionDeniedCount = permissionDeniedCount
        self.unreadableItemCount = unreadableItemCount
        self.measuredAt = measuredAt
    }

    /// An incomplete size is a lower bound: unreadable contents can only add to it.
    public var isComplete: Bool { permissionDeniedCount == 0 && unreadableItemCount == 0 }
}

public struct FolderSizeAlert: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let watchID: UUID
    public let path: String
    public let sizeBytes: UInt64
    public let thresholdBytes: UInt64
    public let date: Date
    public let isMeasurementComplete: Bool

    public init(
        id: UUID = UUID(),
        watchID: UUID,
        path: String,
        sizeBytes: UInt64,
        thresholdBytes: UInt64,
        date: Date,
        isMeasurementComplete: Bool
    ) {
        self.id = id
        self.watchID = watchID
        self.path = path
        self.sizeBytes = sizeBytes
        self.thresholdBytes = thresholdBytes
        self.date = date
        self.isMeasurementComplete = isMeasurementComplete
    }

    public var name: String { path == "/" ? "/" : URL(fileURLWithPath: path).lastPathComponent }
}

public enum FolderSizeAlertPolicy {
    /// A reached folder re-arms only after a complete measurement drops below 95% of
    /// its threshold, so a folder hovering at the limit does not alert on every check.
    public static func rearmBelowBytes(threshold: UInt64) -> UInt64 {
        threshold - threshold / 20
    }

    public static func evaluate(
        _ state: FolderSizeAlertState,
        measurement: FolderSizeMeasurement,
        thresholdBytes: UInt64
    ) -> (state: FolderSizeAlertState, shouldAlert: Bool) {
        if measurement.sizeBytes >= thresholdBytes {
            if case .armed = state {
                return (.reached(since: measurement.measuredAt), true)
            }
            return (state, false)
        }
        // A partial size cannot prove the folder shrank, so it never re-arms an alert.
        if measurement.isComplete, measurement.sizeBytes < rearmBelowBytes(threshold: thresholdBytes) {
            return (.armed, false)
        }
        return (state, false)
    }
}

public struct FolderSizeWatchList: Equatable, Sendable {
    public private(set) var watches: [FolderSizeWatch]

    public init(_ watches: [FolderSizeWatch] = []) {
        self.watches = watches
    }

    public func watch(id: UUID) -> FolderSizeWatch? {
        watches.first { $0.id == id }
    }

    /// Adds a folder by its resolved path; links and duplicate paths are not watched twice.
    @discardableResult
    public mutating func add(
        folder: URL,
        thresholdBytes: UInt64 = FolderSizeThreshold.defaultBytes,
        fileManager: FileManager = .default
    ) throws -> FolderSizeWatch {
        try FolderSizeThreshold.validate(thresholdBytes)
        let resolved = folder.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            throw FolderSizeWatchError.folderUnavailable(resolved.path)
        }
        guard isDirectory.boolValue else {
            throw FolderSizeWatchError.notAFolder(resolved.path)
        }
        guard !watches.contains(where: { $0.path == resolved.path }) else {
            throw FolderSizeWatchError.alreadyWatched(resolved.path)
        }
        let watch = FolderSizeWatch(path: resolved.path, thresholdBytes: thresholdBytes)
        watches.append(watch)
        return watch
    }

    @discardableResult
    public mutating func remove(id: UUID) -> FolderSizeWatch? {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return nil }
        return watches.remove(at: index)
    }

    /// A new threshold re-arms the alert so the next measurement is judged against it.
    public mutating func setThreshold(_ bytes: UInt64, for id: UUID) throws {
        try FolderSizeThreshold.validate(bytes)
        guard let index = watches.firstIndex(where: { $0.id == id }) else {
            throw FolderSizeWatchError.unknownWatch
        }
        guard watches[index].thresholdBytes != bytes else { return }
        watches[index].thresholdBytes = bytes
        watches[index].alertState = .armed
    }

    public mutating func setEnabled(_ enabled: Bool, for id: UUID) throws {
        guard let index = watches.firstIndex(where: { $0.id == id }) else {
            throw FolderSizeWatchError.unknownWatch
        }
        watches[index].isEnabled = enabled
    }

    /// Applies a measurement to a current, enabled watch of the same folder and returns
    /// an alert when it newly reaches the threshold. Stale measurements are ignored.
    public mutating func record(_ measurement: FolderSizeMeasurement, for id: UUID) -> FolderSizeAlert? {
        guard let index = watches.firstIndex(where: { $0.id == id }),
              watches[index].isEnabled,
              watches[index].path == measurement.path else {
            return nil
        }
        let watch = watches[index]
        let outcome = FolderSizeAlertPolicy.evaluate(
            watch.alertState,
            measurement: measurement,
            thresholdBytes: watch.thresholdBytes
        )
        watches[index].alertState = outcome.state
        guard outcome.shouldAlert else { return nil }
        return FolderSizeAlert(
            watchID: watch.id,
            path: watch.path,
            sizeBytes: measurement.sizeBytes,
            thresholdBytes: watch.thresholdBytes,
            date: measurement.measuredAt,
            isMeasurementComplete: measurement.isComplete
        )
    }

    fileprivate func validationFailure() -> String? {
        var ids: Set<UUID> = []
        var paths: Set<String> = []
        for watch in watches {
            guard ids.insert(watch.id).inserted else { return "duplicate folder identifier" }
            guard watch.path.hasPrefix("/"), paths.insert(watch.path).inserted else {
                return "invalid or duplicate folder path \(watch.path)"
            }
            guard (FolderSizeThreshold.minimumBytes...FolderSizeThreshold.maximumBytes)
                .contains(watch.thresholdBytes) else {
                return "invalid threshold for \(watch.path)"
            }
        }
        return nil
    }
}

public enum FolderSizeWatchError: LocalizedError, Equatable, Sendable {
    case cancelled
    case folderUnavailable(String)
    case notAFolder(String)
    case alreadyWatched(String)
    case unknownWatch
    case invalidThreshold(String)
    case permissionDenied(String)
    case unreadableFolder(String, String)
    case unreadableSavedWatches(String)
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The folder measurement was cancelled."
        case .folderUnavailable(let path):
            return "The folder is unavailable: \(path)"
        case .notAFolder(let path):
            return "Only folders can be watched: \(path)"
        case .alreadyWatched(let path):
            return "This folder is already watched: \(path)"
        case .unknownWatch:
            return "The watched folder no longer exists in KillSwitch."
        case .invalidThreshold(let message):
            return message
        case .permissionDenied(let path):
            return "KillSwitch does not have permission to read \(path). Grant Full Disk Access to measure it."
        case .unreadableFolder(let path, let message):
            return "Could not read \(path): \(message)"
        case .unreadableSavedWatches(let message):
            return "Saved folder alerts could not be read (\(message)). The unreadable data was backed up and the list was reset."
        case .persistenceFailed(let message):
            return "Folder alerts could not be saved: \(message)"
        }
    }
}

/// Measures the total allocated size of a folder like `du`: hidden files and package
/// contents count, symbolic links are not followed, and hard-linked files count once.
public final class FolderSizeMeasurer: @unchecked Sendable {
    // Immutable after initialization; FileManager.default is safe to share across threads.
    private let fileManager: FileManager
    private let workerCount: Int
    private let now: @Sendable () -> Date

    private static let resourceKeys: Set<URLResourceKey> = [
        .fileSizeKey,
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .linkCountKey,
        .totalFileAllocatedSizeKey
    ]

    /// Background monitoring defaults to at most four workers to stay light.
    public init(
        fileManager: FileManager = .default,
        workerCount: Int? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.workerCount = max(1, workerCount ?? min(4, ProcessInfo.processInfo.activeProcessorCount))
        self.now = now
    }

    public func measure(
        _ folder: URL,
        cancellationToken: DiskCleanupCancellationToken = DiskCleanupCancellationToken()
    ) throws -> FolderSizeMeasurement {
        let root = folder.standardizedFileURL
        guard !cancellationToken.isCancelled else { throw FolderSizeWatchError.cancelled }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw FolderSizeWatchError.folderUnavailable(root.path)
        }
        guard isDirectory.boolValue else {
            throw FolderSizeWatchError.notAFolder(root.path)
        }

        let resourceKeys = Self.resourceKeys
        let walk = ParallelDirectoryWalk<Bool, FolderSizePartial>(
            fileManager: fileManager,
            resourceKeys: resourceKeys,
            options: [],
            workerCount: workerCount,
            progressStride: 512,
            progressInterval: 0.15,
            cancellationToken: cancellationToken,
            progress: nil
        )
        let outcome = walk.run(
            root: root,
            context: true,
            makePartial: { FolderSizePartial() },
            listingFailed: { partial, _, isRoot, error in
                if isRoot {
                    partial.rootError = error
                } else {
                    partial.counters.record(error)
                }
            },
            visit: { partial, url, _ in
                let values: URLResourceValues
                do {
                    values = try url.resourceValues(forKeys: resourceKeys)
                } catch {
                    partial.counters.record(error)
                    return nil
                }
                if values.isSymbolicLink == true { return nil }
                if values.isDirectory == true { return false }
                guard values.isRegularFile == true else { return nil }

                let size = DiskCleanupService.diskSize(values)
                if let links = values.linkCount, links > 1 {
                    var info = stat()
                    if lstat(url.path, &info) == 0 {
                        partial.hardLinkedSizes[FileIdentity(device: info.st_dev, inode: info.st_ino)] = size
                        return nil
                    }
                    partial.counters.record(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                    return nil
                }
                partial.sizeBytes += size
                partial.fileCount += 1
                return nil
            }
        )

        guard !cancellationToken.isCancelled else { throw FolderSizeWatchError.cancelled }
        if let rootError = outcome.partials.lazy.compactMap(\.rootError).first {
            if DiskCleanupService.isPermissionError(rootError) {
                throw FolderSizeWatchError.permissionDenied(root.path)
            }
            throw FolderSizeWatchError.unreadableFolder(root.path, rootError.localizedDescription)
        }

        var sizeBytes: UInt64 = 0
        var fileCount = 0
        var counters = DiskScanCounters()
        var hardLinkedSizes: [FileIdentity: UInt64] = [:]
        for partial in outcome.partials {
            sizeBytes += partial.sizeBytes
            fileCount += partial.fileCount
            counters.add(partial.counters)
            hardLinkedSizes.merge(partial.hardLinkedSizes) { first, _ in first }
        }
        sizeBytes += hardLinkedSizes.values.reduce(0, +)
        fileCount += hardLinkedSizes.count

        return FolderSizeMeasurement(
            path: root.path,
            sizeBytes: sizeBytes,
            fileCount: fileCount,
            permissionDeniedCount: counters.permissionDeniedCount,
            unreadableItemCount: counters.skippedItemCount,
            measuredAt: now()
        )
    }
}

private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
}

private struct FolderSizePartial {
    var sizeBytes: UInt64 = 0
    var fileCount = 0
    var hardLinkedSizes: [FileIdentity: UInt64] = [:]
    var counters = DiskScanCounters()
    var rootError: Error?
}

/// Persists watched folders as JSON plus the shared check interval.
public final class FolderSizeWatchStore {
    public static let defaultIntervalSeconds = 900

    private enum Key: String {
        case watches = "foldersize.watches"
        case unreadableBackup = "foldersize.watches.unreadable"
        case intervalSeconds = "foldersize.intervalSeconds"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Unreadable saved data is moved to a backup key rather than silently discarded.
    public func loadWatches() throws -> FolderSizeWatchList {
        guard let data = defaults.data(forKey: Key.watches.rawValue) else {
            return FolderSizeWatchList()
        }
        let failure: String
        do {
            let list = FolderSizeWatchList(try JSONDecoder().decode([FolderSizeWatch].self, from: data))
            guard let invalid = list.validationFailure() else { return list }
            failure = invalid
        } catch {
            failure = error.localizedDescription
        }
        defaults.set(data, forKey: Key.unreadableBackup.rawValue)
        defaults.removeObject(forKey: Key.watches.rawValue)
        throw FolderSizeWatchError.unreadableSavedWatches(failure)
    }

    public func save(_ list: FolderSizeWatchList) throws {
        do {
            defaults.set(try JSONEncoder().encode(list.watches), forKey: Key.watches.rawValue)
        } catch {
            throw FolderSizeWatchError.persistenceFailed(error.localizedDescription)
        }
    }

    public func intervalSeconds(allowed: [Int]) -> Int {
        let stored = defaults.integer(forKey: Key.intervalSeconds.rawValue)
        return allowed.contains(stored) ? stored : Self.defaultIntervalSeconds
    }

    public func setIntervalSeconds(_ seconds: Int) {
        defaults.set(seconds, forKey: Key.intervalSeconds.rawValue)
    }
}
