import Darwin
import Foundation
import SoftwareInventoryCore

public enum MaintenancePath {
    public static func expand(_ path: String, home: URL) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return home.standardizedFileURL.path }
        if trimmed.hasPrefix("~/") { return home.appendingPathComponent(String(trimmed.dropFirst(2))).standardizedFileURL.path }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    public static func abbreviate(_ path: String, home: URL) -> String {
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    /// Resolves every symbolic link, so containment checks cannot be escaped through a link.
    public static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func isDescendant(_ path: String, of root: String, orEqual: Bool = true) -> Bool {
        let child = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let parent = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        guard child.starts(with: parent) else { return false }
        return orEqual || child.count > parent.count
    }

    public static func isInDownloads(_ path: String, home: URL) -> Bool {
        isDescendant(resolved(path), of: resolved(home.appendingPathComponent("Downloads").path))
    }

    public static func relative(_ path: String, to root: String) -> String? {
        let child = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let parent = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        guard child.starts(with: parent), child.count > parent.count else { return nil }
        return child.dropFirst(parent.count).joined(separator: "/")
    }
}

/// The identity of a file system entry, captured without following a final symbolic link.
public struct FileIdentity: Codable, Equatable, Sendable {
    public let device: Int64
    public let inode: UInt64
    public let modified: TimeInterval
    public let changed: TimeInterval
    public let owner: UInt32
    public let isDirectory: Bool
    public let isSymbolicLink: Bool

    public init(device: Int64, inode: UInt64, modified: TimeInterval, changed: TimeInterval,
                owner: UInt32, isDirectory: Bool, isSymbolicLink: Bool) {
        self.device = device
        self.inode = inode
        self.modified = modified
        self.changed = changed
        self.owner = owner
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
    }

    public static func read(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        return FileIdentity(
            device: Int64(info.st_dev), inode: UInt64(info.st_ino),
            modified: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9,
            changed: TimeInterval(info.st_ctimespec.tv_sec) + TimeInterval(info.st_ctimespec.tv_nsec) / 1e9,
            owner: info.st_uid, isDirectory: type == S_IFDIR, isSymbolicLink: type == S_IFLNK
        )
    }

    /// The same entry, unchanged since it was inspected.
    public func matches(_ other: FileIdentity?) -> Bool {
        guard let other else { return false }
        return device == other.device && inode == other.inode && modified == other.modified
            && owner == other.owner && isDirectory == other.isDirectory && isSymbolicLink == other.isSymbolicLink
    }
}

// MARK: - Process usage

/// Every process working directory and open path visible to this account, from one `lsof` read.
/// Only process short names are kept, never full command arguments.
public struct ProcessUsageSnapshot: Sendable {
    public struct OpenPath: Equatable, Sendable {
        public let path: String
        public let process: String

        public init(path: String, process: String) {
            self.path = path
            self.process = process
        }
    }

    /// Disk image helpers hold an attached image's backing file open.
    public static let diskImageHelpers: Set<String> = ["diskimages-helper", "diskimagesiod", "hdiejectd"]

    public let workingDirectories: [Int32: String]
    public let openPaths: [OpenPath]

    public init(workingDirectories: [Int32: String], openPaths: [OpenPath]) {
        self.workingDirectories = workingDirectories
        self.openPaths = openPaths
    }

    public static func parse(_ output: String) -> ProcessUsageSnapshot {
        var cwd: [Int32: String] = [:]
        var open: [OpenPath] = []
        var pid: Int32?
        var process = ""
        var descriptor = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value); process = ""; descriptor = ""
            case "c": process = value
            case "f": descriptor = value
            case "n":
                guard let pid, value.hasPrefix("/") else { continue }
                if descriptor == "cwd" {
                    cwd[pid] = value
                } else {
                    open.append(OpenPath(path: value, process: process))
                }
            default: continue
            }
        }
        return ProcessUsageSnapshot(workingDirectories: cwd, openPaths: open)
    }

    /// Processes whose working directory is the path or inside it.
    public func processes(workingIn path: String) -> [Int32] {
        let resolved = MaintenancePath.resolved(path)
        return workingDirectories.filter { MaintenancePath.isDescendant($0.value, of: resolved) }.map(\.key).sorted()
    }

    /// Whether any process holds the path, or something inside it, open.
    public func isOpen(_ path: String, ignoring processes: Set<String> = []) -> Bool {
        let resolved = MaintenancePath.resolved(path)
        let prefix = resolved.hasSuffix("/") ? resolved : resolved + "/"
        return openPaths.contains { ($0.path == resolved || $0.path.hasPrefix(prefix)) && !processes.contains($0.process) }
    }

    public func isInUse(_ path: String) -> Bool {
        !processes(workingIn: path).isEmpty || isOpen(path)
    }
}

public enum ProcessUsageReader {
    public static let command = SoftwareCommand("/usr/sbin/lsof", arguments: ["-nP", "-w", "-F", "pcfn"], environment: ["LC_ALL": "C"])

    /// Fails closed: without a usable listing, nothing can be proven unused.
    public static func read(runner: SoftwareCommandRunning) throws -> ProcessUsageSnapshot {
        let result = try runner.run(command)
        // lsof exits 1 when some processes are unreadable but still lists the rest.
        guard result.succeeded || (result.status == 1 && !result.output.isEmpty) else {
            throw MaintenanceError.inspectionFailed("lsof exited with status \(result.status): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let snapshot = ProcessUsageSnapshot.parse(result.output)
        guard !snapshot.workingDirectories.isEmpty else {
            throw MaintenanceError.inspectionFailed("lsof did not report any process working directories.")
        }
        return snapshot
    }
}

public enum MaintenanceError: LocalizedError, Equatable, Sendable {
    case inspectionFailed(String)
    case unsafeRoot(String, String)
    case githubUnavailable(String)
    case gitFailed(String)
    case changedSinceInspection(String)
    case trashFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .inspectionFailed(let message): return "Inspection failed: \(message)"
        case let .unsafeRoot(path, reason): return "Refusing to use \(path): \(reason)"
        case .githubUnavailable(let message): return "GitHub verification is unavailable: \(message)"
        case .gitFailed(let message): return "Git failed: \(message)"
        case .changedSinceInspection(let path): return "\(path) changed after it was inspected and was kept."
        case let .trashFailed(path, message): return "Could not move \(path) to the Trash: \(message)"
        }
    }
}

// MARK: - Agent sessions

public struct AgentSession: Identifiable, Equatable, Sendable {
    public var id: String { directory }

    public let directory: String
    public let sessionID: String?
    public let workingDirectory: String?
    public let gitRoot: String?
    public let repository: String?
    public let branch: String?
    public let livePIDs: [Int32]
    public let lastActivity: Date?

    public init(directory: String, sessionID: String?, workingDirectory: String?, gitRoot: String?,
                repository: String?, branch: String?, livePIDs: [Int32], lastActivity: Date?) {
        self.directory = directory
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.gitRoot = gitRoot
        self.repository = repository
        self.branch = branch
        self.livePIDs = livePIDs
        self.lastActivity = lastActivity
    }

    public var workspacePaths: [String] {
        Array(Set([workingDirectory, gitRoot].compactMap { $0 }.map { URL(fileURLWithPath: $0).standardizedFileURL.path }))
    }

    /// Why this session must be protected, or nil when it is demonstrably inactive. A live
    /// harness process cannot prove an idle turn without the app's status, so it protects.
    public func activityReason(now: Date, quietPeriod: TimeInterval) -> String? {
        if !livePIDs.isEmpty { return "its agent process is running (PID \(livePIDs.map(String.init).joined(separator: ", ")))" }
        guard let lastActivity else { return "its activity could not be determined" }
        if now.timeIntervalSince(lastActivity) < quietPeriod { return "it was active \(Int(now.timeIntervalSince(lastActivity) / 60)) minute(s) ago" }
        return nil
    }
}

public enum AgentSessionRegistry {
    public static let metadataFile = "workspace.yaml"

    /// Reads only `workspace.yaml` keys and file times; conversation history is never opened.
    public static func load(
        root: String, isProcessAlive: (Int32) -> Bool = AgentSessionRegistry.isProcessAlive,
        fileManager: FileManager = .default
    ) -> (sessions: [AgentSession], warnings: [String]) {
        guard let children = try? fileManager.contentsOfDirectory(atPath: root) else {
            return ([], fileManager.fileExists(atPath: root) ? ["Session metadata in \(root) could not be listed."] : [])
        }
        var sessions: [AgentSession] = []
        var warnings: [String] = []
        for child in children.sorted() where !child.hasPrefix(".") {
            let directory = (root as NSString).appendingPathComponent(child)
            let metadataPath = (directory as NSString).appendingPathComponent(metadataFile)
            guard fileManager.fileExists(atPath: metadataPath) else { continue }
            guard let text = try? String(contentsOfFile: metadataPath, encoding: .utf8) else {
                warnings.append("\(directory): session metadata could not be read.")
                continue
            }
            let fields = parseMetadata(text)
            let entries = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
            let pids = entries.compactMap(lockPID).filter(isProcessAlive)
            let activityFiles = ["events.jsonl", "session.db", metadataFile, "checkpoints", "files"]
            let lastActivity = activityFiles
                .compactMap { FileIdentity.read((directory as NSString).appendingPathComponent($0))?.modified }
                .max().map { Date(timeIntervalSince1970: $0) }
            sessions.append(AgentSession(
                directory: directory, sessionID: fields["id"], workingDirectory: fields["cwd"], gitRoot: fields["git_root"],
                repository: fields["repository"], branch: fields["branch"], livePIDs: pids.sorted(), lastActivity: lastActivity
            ))
        }
        return (sessions, warnings)
    }

    /// Top-level `key: value` lines only; values are untrusted data and never interpreted.
    public static func parseMetadata(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix(" ") && !line.hasPrefix("\t") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty, result[key] == nil else { continue }
            result[key] = value
        }
        return result
    }

    static func lockPID(_ name: String) -> Int32? {
        guard name.hasPrefix("inuse."), name.hasSuffix(".lock") else { return nil }
        return Int32(name.dropFirst("inuse.".count).dropLast(".lock".count))
    }

    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

// MARK: - Git

public struct GitHubRepository: Hashable, Codable, Sendable, CustomStringConvertible {
    public let owner: String
    public let name: String

    public init?(owner: String, name: String) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !owner.isEmpty, !name.isEmpty, owner.unicodeScalars.allSatisfy(allowed.contains),
              name.unicodeScalars.allSatisfy(allowed.contains), !owner.hasPrefix("."), !name.hasPrefix(".") else { return nil }
        self.owner = owner
        self.name = name
    }

    public var description: String { "\(owner)/\(name)" }

    public init?(slug: String) {
        let parts = slug.split(separator: "/")
        guard parts.count == 2 else { return nil }
        self.init(owner: String(parts[0]), name: String(parts[1]))
    }

    /// Parses github.com HTTPS and SSH remote URLs.
    public init?(remoteURL: String) {
        var path = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/", "git://github.com/"] where path.hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
            if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
            if path.hasSuffix("/") { path = String(path.dropLast()) }
            self.init(slug: path)
            return
        }
        return nil
    }
}

public struct GitCheckoutState: Equatable, Sendable {
    public let topLevel: String
    public let gitDirectory: String
    public let commonDirectory: String
    public let head: String
    public let branch: String?
    public let repository: GitHubRepository?
    public let isClean: Bool
    public let operationInProgress: String?

    public var isLinkedWorktree: Bool { gitDirectory != commonDirectory }
    /// The main checkout that owns this worktree's shared Git directory.
    public var mainCheckout: String { URL(fileURLWithPath: commonDirectory).deletingLastPathComponent().path }
}

public struct GitInspector: Sendable {
    public static let environment = [
        "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
    ]
    private let runner: SoftwareCommandRunning
    private let executable: String

    public init(runner: SoftwareCommandRunning, executable: String = "/usr/bin/git") {
        self.runner = runner
        self.executable = executable
    }

    func command(_ directory: String, _ arguments: [String]) -> SoftwareCommand {
        SoftwareCommand(executable, arguments: ["-C", directory] + arguments, environment: Self.environment)
    }

    private func output(_ directory: String, _ arguments: [String]) throws -> String {
        let result = try runner.run(command(directory, arguments))
        guard result.succeeded else {
            throw MaintenanceError.gitFailed("git \(arguments.joined(separator: " ")) in \(directory): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.output
    }

    public func state(at path: String) throws -> GitCheckoutState {
        let locations = try output(path, ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"])
            .split(separator: "\n").map(String.init)
        guard locations.count == 3 else { throw MaintenanceError.gitFailed("unexpected rev-parse output in \(path)") }
        let head = try output(path, ["rev-parse", "--verify", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let branchResult = try runner.run(command(path, ["symbolic-ref", "-q", "--short", "HEAD"]))
        let branch = branchResult.succeeded ? branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let remote = try? output(path, ["remote", "get-url", "origin"])
        let status = try output(path, ["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"])
        let gitDirectory = URL(fileURLWithPath: locations[1]).standardizedFileURL.path
        let markers = ["MERGE_HEAD": "a merge", "rebase-merge": "a rebase", "rebase-apply": "a rebase or am",
                       "CHERRY_PICK_HEAD": "a cherry-pick", "REVERT_HEAD": "a revert", "BISECT_LOG": "a bisect"]
        let operation = markers.sorted { $0.key < $1.key }.first {
            FileManager.default.fileExists(atPath: (gitDirectory as NSString).appendingPathComponent($0.key))
        }?.value
        return GitCheckoutState(
            topLevel: URL(fileURLWithPath: locations[0]).standardizedFileURL.path,
            gitDirectory: gitDirectory,
            commonDirectory: URL(fileURLWithPath: locations[2]).standardizedFileURL.path,
            head: head, branch: branch.flatMap { $0.isEmpty ? nil : $0 },
            repository: remote.flatMap(GitHubRepository.init(remoteURL:)),
            isClean: status.isEmpty, operationInProgress: operation
        )
    }

    /// Ignored paths relative to the top level; wholly ignored directories end with `/`.
    public func ignoredEntries(at topLevel: String) throws -> [String] {
        try output(topLevel, ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"])
            .split(separator: "\0").map(String.init)
    }

    public func hasTrackedFiles(_ relativePath: String, topLevel: String) throws -> Bool {
        !(try output(topLevel, ["ls-files", "-z", "--", relativePath]).isEmpty)
    }

    public func isIgnored(_ relativePath: String, topLevel: String) throws -> Bool {
        let result = try runner.run(command(topLevel, ["check-ignore", "-q", "--", relativePath]))
        switch result.status {
        case 0: return true
        case 1: return false
        default: throw MaintenanceError.gitFailed("git check-ignore \(relativePath): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    public func linkedWorktrees(of mainCheckout: String) throws -> [String] {
        try output(mainCheckout, ["worktree", "list", "--porcelain"])
            .split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { URL(fileURLWithPath: String($0.dropFirst("worktree ".count))).standardizedFileURL.path }
    }

    /// `git worktree remove` without `--force`: Git refuses dirty or locked worktrees.
    public func removeWorktreeCommand(_ worktree: String, mainCheckout: String) -> SoftwareCommand {
        command(mainCheckout, ["worktree", "remove", worktree])
    }
}

// MARK: - GitHub pull requests

public struct PullRequestRecord: Decodable, Equatable, Sendable {
    public struct Head: Decodable, Equatable, Sendable {
        public let sha: String
        public let ref: String
    }

    public let number: Int
    public let state: String
    public let mergedAt: Date?
    public let head: Head
    public let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case number, state, head
        case mergedAt = "merged_at"
        case htmlURL = "html_url"
    }

    public init(number: Int, state: String, mergedAt: Date?, headSHA: String, headRef: String, htmlURL: String?) {
        self.number = number
        self.state = state
        self.mergedAt = mergedAt
        self.head = Head(sha: headSHA, ref: headRef)
        self.htmlURL = htmlURL
    }
}

public enum PullRequestVerdict: Equatable, Sendable {
    case merged(PullRequestRecord)
    case open(Int)
    case closedUnmerged(Int)
    case headMismatch(Int)
    case notFound

    public var mergedRecord: PullRequestRecord? {
        if case .merged(let record) = self { return record }
        return nil
    }

    public var explanation: String {
        switch self {
        case .merged(let record): return "PR #\(record.number) is merged"
        case .open(let number): return "PR #\(number) is still open"
        case .closedUnmerged(let number): return "PR #\(number) was closed without merging"
        case .headMismatch(let number): return "the checkout has commits beyond merged PR #\(number)"
        case .notFound: return "no pull request was found for its branch"
        }
    }

    /// An open PR always wins; a merged PR counts only when its head matches, if one is required.
    public static func evaluate(_ records: [PullRequestRecord], headSHA: String?) -> PullRequestVerdict {
        if let open = records.first(where: { $0.state == "open" }) { return .open(open.number) }
        let merged = records.filter { $0.mergedAt != nil }.sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }
        if let headSHA {
            if let match = merged.first(where: { $0.head.sha == headSHA }) { return .merged(match) }
            if let latest = merged.first { return .headMismatch(latest.number) }
        } else if let latest = merged.first {
            return .merged(latest)
        }
        if let closed = records.first { return .closedUnmerged(closed.number) }
        return .notFound
    }
}

public struct PullRequestVerifier: Sendable {
    public static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
    private let runner: SoftwareCommandRunning
    public let executable: String?

    public init(runner: SoftwareCommandRunning, executable: String? = PullRequestVerifier.locate()) {
        self.runner = runner
        self.executable = executable
    }

    public static func locate(fileManager: FileManager = .default) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Read-only REST lookup of every PR whose head is the branch, using the existing gh account.
    public func pullRequests(repository: GitHubRepository, branch: String) throws -> [PullRequestRecord] {
        guard let executable else { throw MaintenanceError.githubUnavailable("gh is not installed in /opt/homebrew or /usr/local.") }
        let command = SoftwareCommand(executable, arguments: [
            "api", "-X", "GET", "repos/\(repository.owner)/\(repository.name)/pulls",
            "-f", "state=all", "-f", "head=\(repository.owner):\(branch)", "-f", "per_page=100"
        ], environment: ["GH_PROMPT_DISABLED": "1", "NO_COLOR": "1", "GH_NO_UPDATE_NOTIFIER": "1"])
        let result = try runner.run(command)
        guard result.succeeded else {
            throw MaintenanceError.githubUnavailable("gh api exited with status \(result.status): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([PullRequestRecord].self, from: Data(result.output.utf8))
                .filter { $0.head.ref == branch }
        } catch {
            throw MaintenanceError.githubUnavailable("unexpected gh api output: \(error.localizedDescription)")
        }
    }
}
