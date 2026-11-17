import Foundation

/// Roots and options for maintenance. Defaults cover the Copilot app's session history and
/// worktrees; users can add more roots of either kind.
public struct MaintenanceSettings: Codable, Equatable, Sendable {
    public static let scheduleOptions = [1, 6, 12, 24]
    /// Days between automatic Empty Trash runs.
    public static let trashScheduleOptions = [1, 7, 30]
    public static let defaultTrashScheduleDays = 7

    public var artifactRoots: [String]
    public var repositoryRoots: [String]
    public var scheduleEnabled: Bool
    public var scheduleIntervalHours: Int
    public var archiveIdleHours: Int
    public var buildIdleDays: Int
    /// Off by default. When on, the whole Trash is permanently emptied every interval.
    public var trashScheduleEnabled: Bool
    public var trashScheduleIntervalDays: Int
    /// When the current interval started: when automatic emptying was turned on or last ran.
    /// Persisted so an interval that ends while KillSwitch is closed runs at the next check.
    public var trashScheduleAnchor: Date?

    public init(
        artifactRoots: [String], repositoryRoots: [String], scheduleEnabled: Bool = false,
        scheduleIntervalHours: Int = 24, archiveIdleHours: Int = 24, buildIdleDays: Int = 14,
        trashScheduleEnabled: Bool = false, trashScheduleIntervalDays: Int = MaintenanceSettings.defaultTrashScheduleDays,
        trashScheduleAnchor: Date? = nil
    ) {
        self.artifactRoots = artifactRoots
        self.repositoryRoots = repositoryRoots
        self.scheduleEnabled = scheduleEnabled
        self.scheduleIntervalHours = scheduleIntervalHours
        self.archiveIdleHours = archiveIdleHours
        self.buildIdleDays = buildIdleDays
        self.trashScheduleEnabled = trashScheduleEnabled
        self.trashScheduleIntervalDays = trashScheduleIntervalDays
        self.trashScheduleAnchor = trashScheduleAnchor
    }

    private enum CodingKeys: String, CodingKey {
        case artifactRoots, repositoryRoots, scheduleEnabled, scheduleIntervalHours, archiveIdleHours, buildIdleDays
        case trashScheduleEnabled, trashScheduleIntervalDays, trashScheduleAnchor
    }

    /// Settings saved before automatic emptying existed decode with it off.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            artifactRoots: try container.decode([String].self, forKey: .artifactRoots),
            repositoryRoots: try container.decode([String].self, forKey: .repositoryRoots),
            scheduleEnabled: try container.decode(Bool.self, forKey: .scheduleEnabled),
            scheduleIntervalHours: try container.decode(Int.self, forKey: .scheduleIntervalHours),
            archiveIdleHours: try container.decode(Int.self, forKey: .archiveIdleHours),
            buildIdleDays: try container.decode(Int.self, forKey: .buildIdleDays),
            trashScheduleEnabled: try container.decodeIfPresent(Bool.self, forKey: .trashScheduleEnabled) ?? false,
            trashScheduleIntervalDays: try container.decodeIfPresent(Int.self, forKey: .trashScheduleIntervalDays)
                ?? MaintenanceSettings.defaultTrashScheduleDays,
            trashScheduleAnchor: try container.decodeIfPresent(Date.self, forKey: .trashScheduleAnchor)
        )
    }

    /// When the next automatic Empty Trash is due, or nil while it is off.
    public var nextTrashEmpty: Date? {
        guard trashScheduleEnabled, let anchor = trashScheduleAnchor else { return nil }
        return anchor.addingTimeInterval(TimeInterval(trashScheduleIntervalDays) * 86_400)
    }

    public func isTrashEmptyDue(now: Date) -> Bool {
        nextTrashEmpty.map { now >= $0 } ?? false
    }

    public static func defaultArtifactRoots(home: URL) -> [String] {
        [".copilot/session-state", "workspace/copilot-worktrees"].map { home.appendingPathComponent($0).path }
    }

    /// The skill's repository roots that exist on this Mac.
    public static func defaultRepositoryRoots(home: URL, fileManager: FileManager = .default) -> [String] {
        ["Projects", "workspace", "Developer", "src", "code"].map { home.appendingPathComponent($0).path }
            .filter { fileManager.fileExists(atPath: $0) }
    }

    public static func defaults(home: URL) -> MaintenanceSettings {
        MaintenanceSettings(artifactRoots: defaultArtifactRoots(home: home), repositoryRoots: defaultRepositoryRoots(home: home))
    }

    /// Validates and resolves roots when an operation starts, because a saved or default root can
    /// later become a link into a protected location. Rejected roots are returned with reasons.
    public static func validRoots(_ roots: [String], home: URL, fileManager: FileManager = .default)
        -> (roots: [String], rejected: [MaintenanceFinding]) {
        var valid: [String] = []
        var rejected: [MaintenanceFinding] = []
        for root in roots {
            do {
                let path = try validateRoot(root, home: home, fileManager: fileManager)
                if !valid.contains(path) { valid.append(path) }
            } catch {
                rejected.append(MaintenanceFinding(path: root, reason: error.localizedDescription))
            }
        }
        return (valid, rejected)
    }

    /// A root must be an existing folder inside the home folder, not the home folder itself,
    /// `~/Downloads`, `~/Library`, or the Trash.
    public static func validateRoot(_ path: String, home: URL, fileManager: FileManager = .default) throws -> String {
        let expanded = MaintenancePath.expand(path, home: home)
        let resolved = MaintenancePath.resolved(expanded)
        let resolvedHome = MaintenancePath.resolved(home.path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MaintenanceError.unsafeRoot(expanded, "it is not an existing folder")
        }
        guard MaintenancePath.isDescendant(resolved, of: resolvedHome, orEqual: false) else {
            throw MaintenanceError.unsafeRoot(expanded, "roots must be inside your home folder, not the home folder itself")
        }
        for protected in ["Downloads", "Library", ".Trash"] {
            let protectedPath = MaintenancePath.resolved(home.appendingPathComponent(protected).path)
            if MaintenancePath.isDescendant(resolved, of: protectedPath) || MaintenancePath.isDescendant(protectedPath, of: resolved) {
                throw MaintenanceError.unsafeRoot(expanded, "~/\(protected) is never a maintenance root")
            }
        }
        return resolved
    }
}

public final class MaintenanceSettingsStore {
    private static let key = "maintenance.settings"
    private let defaults: UserDefaults
    private let home: URL

    private let now: () -> Date

    public init(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.home = home
        self.now = now
    }

    /// Unreadable saved settings fall back to the defaults and report why.
    public func load() -> (settings: MaintenanceSettings, warning: String?) {
        guard let data = defaults.data(forKey: Self.key) else { return (.defaults(home: home), nil) }
        do {
            var settings = try JSONDecoder().decode(MaintenanceSettings.self, from: data)
            if !MaintenanceSettings.scheduleOptions.contains(settings.scheduleIntervalHours) { settings.scheduleIntervalHours = 24 }
            settings.archiveIdleHours = max(1, settings.archiveIdleHours)
            settings.buildIdleDays = max(1, settings.buildIdleDays)
            if !MaintenanceSettings.trashScheduleOptions.contains(settings.trashScheduleIntervalDays) {
                settings.trashScheduleIntervalDays = MaintenanceSettings.defaultTrashScheduleDays
            }
            // Without a recorded start, or with one in the future after a clock change, a new
            // interval starts now rather than emptying immediately.
            if settings.trashScheduleEnabled, settings.trashScheduleAnchor.map({ $0 > now() }) ?? true {
                settings.trashScheduleAnchor = now()
            }
            return (settings, nil)
        } catch {
            return (.defaults(home: home), "Saved maintenance settings could not be read (\(error.localizedDescription)); defaults are shown.")
        }
    }

    public func save(_ settings: MaintenanceSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: Self.key)
    }
}

// MARK: - Audit log

/// Appends one JSON object per line, rotating at a size limit and keeping two older copies.
public struct MaintenanceAuditLog: Sendable {
    public static func defaultURL(home: URL) -> URL {
        home.appendingPathComponent(".copilot/logs/merged-artifact-cleanup.jsonl")
    }

    public let url: URL
    public let maximumBytes: Int
    public let rotatedCopies: Int

    public init(url: URL, maximumBytes: Int = 5 * 1_024 * 1_024, rotatedCopies: Int = 2) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.rotatedCopies = rotatedCopies
    }

    public func append<Record: Encodable>(_ record: Record, fileManager: FileManager = .default) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(record)
        line.append(0x0A)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let currentSize = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if currentSize > 0, currentSize + line.count > maximumBytes {
            try rotate(fileManager: fileManager)
        }
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw MaintenanceError.inspectionFailed("the audit log could not be created at \(url.path)")
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func rotatedURL(_ index: Int) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(index)")
    }

    private func rotate(fileManager: FileManager) throws {
        let oldest = rotatedURL(rotatedCopies)
        if fileManager.fileExists(atPath: oldest.path) { try fileManager.removeItem(at: oldest) }
        if rotatedCopies > 1 {
            for index in stride(from: rotatedCopies - 1, through: 1, by: -1) {
                let source = rotatedURL(index)
                if fileManager.fileExists(atPath: source.path) { try fileManager.moveItem(at: source, to: rotatedURL(index + 1)) }
            }
        }
        try fileManager.moveItem(at: url, to: rotatedURL(1))
    }
}

// MARK: - 24-hour summary

public struct MaintenanceRunSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { date }
    /// Marks an Empty Trash run whose bytes are measured free space, not moved items.
    public static let spaceFreedNote = "Space freed"
    /// Marks an Empty Trash run whose free-space change could not be measured.
    public static let spaceUnavailableNote = "Space change unavailable"

    public let date: Date
    public let task: String
    public let mode: String
    public let trashedCount: Int
    public let trashedBytes: UInt64
    public let protectedCount: Int
    public let errorCount: Int
    public let note: String?

    public init(date: Date, task: String, mode: String, trashedCount: Int, trashedBytes: UInt64,
                protectedCount: Int, errorCount: Int, note: String? = nil) {
        self.date = date
        self.task = task
        self.mode = mode
        self.trashedCount = trashedCount
        self.trashedBytes = trashedBytes
        self.protectedCount = protectedCount
        self.errorCount = errorCount
        self.note = note
    }
}

/// Keeps a few numbers per run for the last 24 hours, never paths or file contents.
public final class MaintenanceHistoryStore {
    public static let retention: TimeInterval = 24 * 3_600
    private static let key = "maintenance.history"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(now: Date = Date()) -> [MaintenanceRunSummary] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([MaintenanceRunSummary].self, from: data) else { return [] }
        return Self.recent(entries, now: now)
    }

    @discardableResult
    public func append(_ summary: MaintenanceRunSummary, now: Date = Date()) -> [MaintenanceRunSummary] {
        let entries = Self.recent(load(now: now) + [summary], now: now)
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
        return entries
    }

    static func recent(_ entries: [MaintenanceRunSummary], now: Date) -> [MaintenanceRunSummary] {
        entries.filter { now.timeIntervalSince($0.date) <= retention && $0.date <= now.addingTimeInterval(60) }
            .sorted { $0.date > $1.date }
    }
}
