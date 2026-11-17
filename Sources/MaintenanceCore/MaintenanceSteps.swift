import Darwin
import Foundation
import SoftwareInventoryCore

public enum CheckoutDiscovery {
    /// Folders with a `.git` entry up to three levels below a root; session folders and links are not entered.
    public static func find(roots: [String], maximumDepth: Int = 3, fileManager: FileManager = .default) -> [String] {
        var found: [String] = []
        for root in roots {
            var queue: [(String, Int)] = [(root, 0)]
            while let (directory, depth) = queue.popLast() {
                guard let children = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
                if depth > 0, children.contains(".git") {
                    found.append(directory)
                    continue
                }
                guard depth < maximumDepth, !children.contains(AgentSessionRegistry.metadataFile) else { continue }
                for child in children where !child.hasPrefix(".") {
                    let path = (directory as NSString).appendingPathComponent(child)
                    if let identity = FileIdentity.read(path), identity.isDirectory, !identity.isSymbolicLink {
                        queue.append((path, depth + 1))
                    }
                }
            }
        }
        return Array(Set(found)).sorted()
    }

    /// A root holding agent session history, which every maintenance step except merged artifacts leaves alone.
    public static func isSessionRoot(_ root: String, fileManager: FileManager = .default) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(atPath: root) else { return false }
        return children.prefix(200).contains {
            fileManager.fileExists(atPath: ((root as NSString).appendingPathComponent($0) as NSString).appendingPathComponent(AgentSessionRegistry.metadataFile))
        }
    }
}

/// One file or folder a maintenance step proposes to move to the Trash.
public struct TrashCandidate: Identifiable, Codable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let detail: String
    public let sizeBytes: UInt64
    public let identity: FileIdentity
    /// The checkout whose cleanliness and HEAD must be unchanged when the item is trashed.
    public let checkout: String?
    public let checkoutHead: String?
    /// Build output requires a clean checkout; an untracked archive only requires staying untracked.
    public let requiresCleanCheckout: Bool

    public init(path: String, detail: String, sizeBytes: UInt64, identity: FileIdentity, checkout: String? = nil,
                checkoutHead: String? = nil, requiresCleanCheckout: Bool = true) {
        self.path = path
        self.detail = detail
        self.sizeBytes = sizeBytes
        self.identity = identity
        self.checkout = checkout
        self.checkoutHead = checkoutHead
        self.requiresCleanCheckout = requiresCleanCheckout
    }
}

public struct TrashScan: Codable, Equatable, Sendable {
    public var date: Date
    public var candidates: [TrashCandidate] = []
    public var kept: [MaintenanceFinding] = []
    public var errors: [String] = []
    public var isComplete = true

    public var totalBytes: UInt64 { candidates.reduce(0) { $0 + $1.sizeBytes } }
}

public struct TrashRunResult: Codable, Equatable, Sendable {
    public var trashed: [TrashCandidate] = []
    public var kept: [MaintenanceFinding] = []
    public var errors: [String] = []

    public var trashedBytes: UInt64 { trashed.reduce(0) { $0 + $1.sizeBytes } }
}

/// Shared context for the mac-maintenance steps formalized from the skill.
public struct MaintenanceStepEnvironment {
    public var runner: SoftwareCommandRunning
    public var home: URL
    public var now: () -> Date
    public var isProcessAlive: (Int32) -> Bool
    public var trash: MaintenanceTrashMover
    public var gitExecutable: String
    public var userID: UInt32
    public var fileManager: FileManager

    public init(
        runner: SoftwareCommandRunning = NativeSoftwareCommandRunner(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping () -> Date = { Date() },
        isProcessAlive: @escaping (Int32) -> Bool = AgentSessionRegistry.isProcessAlive,
        trash: @escaping MaintenanceTrashMover = MaintenanceTrash.system,
        gitExecutable: String = "/usr/bin/git",
        userID: UInt32 = getuid(),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.home = home
        self.now = now
        self.isProcessAlive = isProcessAlive
        self.trash = trash
        self.gitExecutable = gitExecutable
        self.userID = userID
        self.fileManager = fileManager
    }

    var git: GitInspector { GitInspector(runner: runner, executable: gitExecutable) }

    func activeSessions() -> [AgentSession] {
        AgentSessionRegistry.load(root: home.appendingPathComponent(".copilot/session-state").path, isProcessAlive: isProcessAlive, fileManager: fileManager)
            .sessions.filter { $0.activityReason(now: now(), quietPeriod: 15 * 60) != nil }
    }

    /// Why a checkout is active and must be left alone, or nil.
    func checkoutActivity(_ path: String, usage: ProcessUsageSnapshot, sessions: [AgentSession]) -> String? {
        if !usage.processes(workingIn: path).isEmpty { return "a process is working in it" }
        if sessions.contains(where: { session in
            session.workspacePaths.contains { MaintenancePath.isDescendant($0, of: path) || MaintenancePath.isDescendant(path, of: $0) }
        }) {
            return "an agent session using it is active"
        }
        return nil
    }

    private func checkoutRecheck(_ checkout: String, head: String?, requiresClean: Bool, usage: ProcessUsageSnapshot, sessions: [AgentSession]) -> String? {
        if let reason = checkoutActivity(checkout, usage: usage, sessions: sessions) { return reason }
        guard requiresClean else { return nil }
        guard let state = try? git.state(at: checkout) else { return "its Git state could not be read again" }
        if !state.isClean { return "its checkout now has changes" }
        if let head, state.head != head { return "its checkout moved to another commit" }
        return nil
    }

    /// Rechecks identity and use immediately before trashing each candidate, then moves it to the Trash.
    public func trash(_ candidates: [TrashCandidate], recheck: (TrashCandidate) -> String? = { _ in nil }) -> TrashRunResult {
        var result = TrashRunResult()
        let usage: ProcessUsageSnapshot
        do {
            usage = try ProcessUsageReader.read(runner: runner)
        } catch {
            result.errors.append(error.localizedDescription)
            result.kept = candidates.map { MaintenanceFinding(path: $0.path, reason: "nothing was moved because inspection failed") }
            return result
        }
        let sessions = activeSessions()
        var checkoutState: [String: String?] = [:]
        for candidate in candidates {
            guard candidate.identity.matches(FileIdentity.read(candidate.path)) else {
                result.kept.append(MaintenanceFinding(path: candidate.path, reason: "it changed after inspection"))
                continue
            }
            if MaintenancePath.isInDownloads(candidate.path, home: home), !candidate.path.lowercased().hasSuffix(".dmg") {
                result.kept.append(MaintenanceFinding(path: candidate.path, reason: "~/Downloads is never cleaned here"))
                continue
            }
            if usage.isOpen(candidate.path) {
                result.kept.append(MaintenanceFinding(path: candidate.path, reason: "a process has it open"))
                continue
            }
            if let checkout = candidate.checkout {
                let key = "\(checkout)|\(candidate.requiresCleanCheckout)"
                if checkoutState[key] == nil {
                    checkoutState[key] = .some(checkoutRecheck(
                        checkout, head: candidate.checkoutHead, requiresClean: candidate.requiresCleanCheckout, usage: usage, sessions: sessions
                    ))
                }
                if let reason = checkoutState[key] ?? nil {
                    result.kept.append(MaintenanceFinding(path: candidate.path, reason: reason))
                    continue
                }
            }
            if let reason = recheck(candidate) {
                result.kept.append(MaintenanceFinding(path: candidate.path, reason: reason))
                continue
            }
            do {
                try trash(URL(fileURLWithPath: candidate.path))
                result.trashed.append(candidate)
            } catch {
                result.errors.append(MaintenanceError.trashFailed(candidate.path, error.localizedDescription).localizedDescription)
            }
        }
        return result
    }
}

// MARK: - Archives in agent worktrees

public enum ArchiveSweeper {
    public static let archiveExtensions: Set<String> = ["tar", "tgz", "gz", "bz2", "xz", "zst", "lz4", "zip", "7z", "rar", "xip"]
    static let skippedDirectories: Set<String> = [
        ".git", "node_modules", "vendor", ".venv", "venv", "Pods", ".gradle", ".m2", ".yarn", ".terraform",
        "DerivedData", "cache", ".cache", "Caches", ".pnpm-store"
    ]

    public static func isArchive(_ name: String) -> Bool {
        archiveExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Untracked, idle, closed archives in agent worktrees and loose in worktree roots.
    /// Session history roots are never scanned.
    public static func scan(roots: [String], minimumIdleHours: Int, environment: MaintenanceStepEnvironment) -> TrashScan {
        var scan = TrashScan(date: environment.now())
        let usage: ProcessUsageSnapshot
        do {
            usage = try ProcessUsageReader.read(runner: environment.runner)
        } catch {
            scan.errors.append(error.localizedDescription)
            scan.isComplete = false
            return scan
        }
        let sessions = environment.activeSessions()
        let worktreeRoots = roots.filter { !CheckoutDiscovery.isSessionRoot($0, fileManager: environment.fileManager) }
        let checkouts = CheckoutDiscovery.find(roots: worktreeRoots, fileManager: environment.fileManager)
        let idle = TimeInterval(max(1, minimumIdleHours)) * 3_600
        for checkout in checkouts {
            if let reason = environment.checkoutActivity(checkout, usage: usage, sessions: sessions) {
                scan.kept.append(MaintenanceFinding(path: checkout, reason: reason))
                continue
            }
            guard let state = try? environment.git.state(at: checkout) else {
                scan.kept.append(MaintenanceFinding(path: checkout, reason: "its Git state could not be read"))
                continue
            }
            for path in archives(in: checkout, excluding: [], fileManager: environment.fileManager) {
                guard let relative = MaintenancePath.relative(path, to: state.topLevel) else { continue }
                do {
                    if try environment.git.hasTrackedFiles(relative, topLevel: state.topLevel) {
                        scan.kept.append(MaintenanceFinding(path: path, reason: "Git tracks it"))
                        continue
                    }
                } catch {
                    scan.kept.append(MaintenanceFinding(path: path, reason: error.localizedDescription))
                    continue
                }
                consider(path, checkout: state.topLevel, head: state.head, idle: idle, usage: usage, scan: &scan, environment: environment)
            }
        }
        for root in worktreeRoots {
            for path in archives(in: root, excluding: Set(checkouts), maximumDepth: 3, fileManager: environment.fileManager) {
                consider(path, checkout: nil, head: nil, idle: idle, usage: usage, scan: &scan, environment: environment)
            }
        }
        scan.candidates.sort { $0.sizeBytes > $1.sizeBytes }
        return scan
    }

    private static func consider(
        _ path: String, checkout: String?, head: String?, idle: TimeInterval, usage: ProcessUsageSnapshot,
        scan: inout TrashScan, environment: MaintenanceStepEnvironment
    ) {
        guard let identity = FileIdentity.read(path), !identity.isSymbolicLink, identity.owner == environment.userID else { return }
        let age = environment.now().timeIntervalSince1970 - max(identity.modified, identity.changed)
        if age < idle {
            scan.kept.append(MaintenanceFinding(path: path, reason: "used \(Int(age / 3_600)) hour(s) ago"))
            return
        }
        if usage.isOpen(path) {
            scan.kept.append(MaintenanceFinding(path: path, reason: "a process has it open"))
            return
        }
        let size = ArtifactInspector.inspect(path, checkLocalConfiguration: false, fileManager: environment.fileManager).sizeBytes
        scan.candidates.append(TrashCandidate(
            path: path, detail: checkout.map { "Untracked archive in \(($0 as NSString).lastPathComponent)" } ?? "Archive outside any checkout",
            sizeBytes: size, identity: identity, checkout: checkout, checkoutHead: head, requiresCleanCheckout: false
        ))
    }

    /// Walks without following links or entering `.app` bundles, dependency caches, or nested repositories.
    static func archives(in root: String, excluding: Set<String>, maximumDepth: Int = 8, fileManager: FileManager) -> [String] {
        var found: [String] = []
        var queue: [(String, Int)] = [(root, 0)]
        while let (directory, depth) = queue.popLast() {
            guard let children = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            if depth > 0, children.contains(".git") { continue }
            for child in children where !skippedDirectories.contains(child) {
                let path = (directory as NSString).appendingPathComponent(child)
                guard !excluding.contains(path), let identity = FileIdentity.read(path), !identity.isSymbolicLink else { continue }
                if identity.isDirectory {
                    if depth < maximumDepth, !child.lowercased().hasSuffix(".app"),
                       !fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(AgentSessionRegistry.metadataFile)) {
                        queue.append((path, depth + 1))
                    }
                } else if isArchive(child) {
                    found.append(path)
                }
            }
        }
        return found.sorted()
    }
}

extension ArchiveSweeper {
    /// Apply-time recheck: an archive inside a checkout must still be untracked.
    public static func recheck(_ candidate: TrashCandidate, environment: MaintenanceStepEnvironment) -> String? {
        guard let checkout = candidate.checkout, let relative = MaintenancePath.relative(candidate.path, to: checkout) else { return nil }
        guard let tracked = try? environment.git.hasTrackedFiles(relative, topLevel: checkout) else { return "its Git status could not be read again" }
        return tracked ? "Git now tracks it" : nil
    }
}

// MARK: - Installed disk images

public struct DiskImageApplication: Equatable, Sendable {
    public let bundleIdentifier: String
    public let name: String
    public let version: String?
    public let build: String?

    public init(bundleIdentifier: String, name: String, version: String?, build: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.build = build
    }
}

public enum AppVersionComparison {
    /// Numeric dotted comparison; nil when either label has non-numeric parts and cannot be ordered.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        func parts(_ value: String) -> [Int]? {
            let pieces = value.split(separator: ".")
            let numbers = pieces.compactMap { Int($0) }
            return numbers.count == pieces.count && !numbers.isEmpty ? numbers : nil
        }
        guard let left = parts(lhs), let right = parts(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Installed at the same or a newer version; the same version needs an equal or newer build.
    public static func isCovered(image: DiskImageApplication, installed: [DiskImageApplication]) -> Bool {
        installed.contains { app in
            guard app.bundleIdentifier == image.bundleIdentifier, let have = app.version, let want = image.version,
                  let order = compare(have, want) else { return false }
            if order == .orderedDescending { return true }
            guard order == .orderedSame else { return false }
            guard let wantBuild = image.build else { return true }
            guard let haveBuild = app.build else { return false }
            if let buildOrder = compare(haveBuild, wantBuild) { return buildOrder != .orderedAscending }
            return haveBuild == wantBuild
        }
    }
}

public enum InstalledDiskImageFinder {
    public static func scanDirectories(home: URL) -> [String] {
        ["Downloads", "Desktop"].map { home.appendingPathComponent($0).path }
    }

    /// Top-level DMGs in Downloads and Desktop whose every app is already installed. Each
    /// image is attached read-only and hidden, read, and detached again; nothing else in
    /// those folders is opened.
    public static func scan(environment: MaintenanceStepEnvironment, applicationRoots: [URL]? = nil) -> TrashScan {
        var scan = TrashScan(date: environment.now())
        let usage: ProcessUsageSnapshot
        let attached: [AttachedDiskImage]
        do {
            usage = try ProcessUsageReader.read(runner: environment.runner)
            attached = try DiskImageInspector.read(runner: environment.runner)
        } catch {
            scan.errors.append(error.localizedDescription)
            scan.isComplete = false
            return scan
        }
        let installed = ApplicationScanner(roots: applicationRoots ?? ApplicationScanner.defaultRoots(home: environment.home)).scan()
            .applications.compactMap { app -> DiskImageApplication? in
                guard let identifier = app.bundleIdentifier else { return nil }
                let info = infoDictionary(app.path)
                return DiskImageApplication(bundleIdentifier: identifier, name: app.name,
                                            version: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String)
            }
        for directory in scanDirectories(home: environment.home) {
            guard let children = try? environment.fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for child in children.sorted() where child.lowercased().hasSuffix(".dmg") {
                let path = (directory as NSString).appendingPathComponent(child)
                guard let identity = FileIdentity.read(path), !identity.isSymbolicLink, !identity.isDirectory,
                      identity.owner == environment.userID else { continue }
                if attached.contains(where: { MaintenancePath.resolved($0.imagePath) == MaintenancePath.resolved(path) }) || usage.isOpen(path) {
                    scan.kept.append(MaintenanceFinding(path: path, reason: "it is mounted or open"))
                    continue
                }
                switch applications(in: path, runner: environment.runner) {
                case .failure(let reason):
                    scan.kept.append(MaintenanceFinding(path: path, reason: reason.message))
                case .success(let apps):
                    let missing = apps.filter { !AppVersionComparison.isCovered(image: $0, installed: installed) }
                    if apps.isEmpty {
                        scan.kept.append(MaintenanceFinding(path: path, reason: "it contains no app"))
                    } else if let first = missing.first {
                        scan.kept.append(MaintenanceFinding(path: path, reason: "\(first.name) \(first.version ?? "") is not installed at that version or newer"))
                    } else {
                        let size = ArtifactInspector.inspect(path, checkLocalConfiguration: false, fileManager: environment.fileManager).sizeBytes
                        scan.candidates.append(TrashCandidate(
                            path: path, detail: "Installed: " + apps.map { "\($0.name) \($0.version ?? "")" }.joined(separator: ", "),
                            sizeBytes: size, identity: identity
                        ))
                    }
                }
            }
        }
        return scan
    }

    public struct ReadFailure: Error, Equatable {
        public let message: String
    }

    static func applications(in path: String, runner: SoftwareCommandRunning) -> Result<[DiskImageApplication], ReadFailure> {
        func plist(_ command: SoftwareCommand) -> [String: Any]? {
            guard let result = try? runner.run(command), result.succeeded else { return nil }
            return try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: Any]
        }
        guard let encryption = plist(SoftwareCommand("/usr/bin/hdiutil", arguments: ["isencrypted", "-plist", path])) else {
            return .failure(ReadFailure(message: "its encryption state could not be read"))
        }
        if encryption["encrypted"] as? Bool != false { return .failure(ReadFailure(message: "it is encrypted")) }
        guard let info = plist(SoftwareCommand("/usr/bin/hdiutil", arguments: ["imageinfo", "-plist", path])),
              let properties = info["Properties"] as? [String: Any] else {
            return .failure(ReadFailure(message: "it could not be read"))
        }
        if properties["Software License Agreement"] as? Bool == true { return .failure(ReadFailure(message: "it requires accepting a license")) }
        let mountRoot = FileManager.default.temporaryDirectory.appendingPathComponent("killswitch-dmg-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        } catch {
            return .failure(ReadFailure(message: "a temporary mount folder could not be created"))
        }
        defer { try? FileManager.default.removeItem(at: mountRoot) }
        guard let attach = plist(SoftwareCommand("/usr/bin/hdiutil", arguments: [
            "attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-plist", "-mountrandom", mountRoot.path, path
        ])) else {
            return .failure(ReadFailure(message: "it could not be attached read-only"))
        }
        let entities = attach["system-entities"] as? [[String: Any]] ?? []
        let device = entities.compactMap { $0["dev-entry"] as? String }
            .first { $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil }
        defer {
            if let device { _ = try? runner.run(DiskImageInspector.detachCommand(device)) }
        }
        var apps: [DiskImageApplication] = []
        for mount in entities.compactMap({ $0["mount-point"] as? String }) {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: mount)) ?? []
            for child in children where child.lowercased().hasSuffix(".app") {
                let info = infoDictionary((mount as NSString).appendingPathComponent(child))
                guard let identifier = info["CFBundleIdentifier"] as? String else { continue }
                apps.append(DiskImageApplication(
                    bundleIdentifier: identifier, name: (child as NSString).deletingPathExtension,
                    version: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String
                ))
            }
        }
        return .success(apps)
    }

    static func infoDictionary(_ appPath: String) -> [String: Any] {
        let url = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
    }
}

// MARK: - Idle build output

public enum IdleBuildOutputFinder {
    public static let directoryNames: Set<String> = ["target", "node_modules", "build"]

    /// Ignored `target`, `node_modules`, and `build` folders in clean checkouts nobody has used
    /// for the idle period; checkouts are direct children of the repository roots and their worktrees.
    public static func scan(repositoryRoots: [String], idleDays: Int, environment: MaintenanceStepEnvironment) -> TrashScan {
        var scan = TrashScan(date: environment.now())
        let usage: ProcessUsageSnapshot
        do {
            usage = try ProcessUsageReader.read(runner: environment.runner)
        } catch {
            scan.errors.append(error.localizedDescription)
            scan.isComplete = false
            return scan
        }
        let sessions = environment.activeSessions()
        let idle = TimeInterval(max(1, idleDays)) * 86_400
        var checkouts = Set<String>()
        for root in repositoryRoots {
            for child in (try? environment.fileManager.contentsOfDirectory(atPath: root)) ?? [] where !child.hasPrefix(".") {
                let path = (root as NSString).appendingPathComponent(child)
                var isDirectory: ObjCBool = false
                guard environment.fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(".git"), isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                checkouts.insert(path)
                for worktree in (try? environment.git.linkedWorktrees(of: path)) ?? [] where !MaintenancePath.isInDownloads(worktree, home: environment.home) {
                    checkouts.insert(worktree)
                }
            }
        }
        for checkout in checkouts.sorted() where environment.fileManager.fileExists(atPath: checkout) {
            if let reason = environment.checkoutActivity(checkout, usage: usage, sessions: sessions) {
                scan.kept.append(MaintenanceFinding(path: checkout, reason: reason))
                continue
            }
            guard let state = try? environment.git.state(at: checkout) else {
                scan.kept.append(MaintenanceFinding(path: checkout, reason: "its Git state could not be read"))
                continue
            }
            if let operation = state.operationInProgress {
                scan.kept.append(MaintenanceFinding(path: checkout, reason: "\(operation) is in progress"))
                continue
            }
            let entries = (try? environment.git.ignoredEntries(at: state.topLevel)) ?? []
            let candidates = entries.filter { $0.hasSuffix("/") && directoryNames.contains(String($0.dropLast().split(separator: "/").last ?? "")) }
            guard !candidates.isEmpty else { continue }
            guard state.isClean else {
                scan.kept.append(MaintenanceFinding(path: checkout, reason: "it has uncommitted or untracked changes"))
                continue
            }
            let lastGitUse = ["HEAD", "index", "logs/HEAD"]
                .compactMap { FileIdentity.read((state.gitDirectory as NSString).appendingPathComponent($0))?.modified }.max() ?? 0
            let now = environment.now().timeIntervalSince1970
            if now - lastGitUse < idle {
                scan.kept.append(MaintenanceFinding(path: checkout, reason: "used \(Int((now - lastGitUse) / 86_400)) day(s) ago"))
                continue
            }
            for entry in candidates {
                let path = (state.topLevel as NSString).appendingPathComponent(String(entry.dropLast()))
                guard let identity = FileIdentity.read(path), identity.isDirectory, !identity.isSymbolicLink,
                      identity.owner == environment.userID,
                      MaintenancePath.isDescendant(MaintenancePath.resolved(path), of: MaintenancePath.resolved(state.topLevel), orEqual: false) else { continue }
                if now - identity.modified < idle {
                    scan.kept.append(MaintenanceFinding(path: path, reason: "built \(Int((now - identity.modified) / 86_400)) day(s) ago"))
                    continue
                }
                if usage.isOpen(path) {
                    scan.kept.append(MaintenanceFinding(path: path, reason: "a process has files open in it"))
                    continue
                }
                if (try? environment.git.hasTrackedFiles(String(entry.dropLast()), topLevel: state.topLevel)) != false {
                    scan.kept.append(MaintenanceFinding(path: path, reason: "Git tracks files inside it, or that could not be checked"))
                    continue
                }
                let inspection = ArtifactInspector.inspect(path, checkLocalConfiguration: false, fileManager: environment.fileManager)
                if !inspection.nestedGitPaths.isEmpty {
                    scan.kept.append(MaintenanceFinding(path: path, reason: "it contains a nested Git checkout"))
                    continue
                }
                scan.candidates.append(TrashCandidate(
                    path: path, detail: "Ignored \((path as NSString).lastPathComponent) in \((state.topLevel as NSString).lastPathComponent)",
                    sizeBytes: inspection.sizeBytes, identity: identity, checkout: state.topLevel, checkoutHead: state.head
                ))
            }
        }
        scan.candidates.sort { $0.sizeBytes > $1.sizeBytes }
        return scan
    }
}

// MARK: - Tool caches

public struct ToolCache: Identifiable, Equatable, Sendable {
    public enum Clearing: Equatable, Sendable {
        /// Run the tool's own clean command.
        case command(tool: String, arguments: [String], whileRunning: [String]?)
        /// Move these folders below the cache to the Trash.
        case trash(subpaths: [String])
        /// Move all but the newest revision of each Playwright browser to the Trash.
        case playwrightOldRevisions
    }

    public let id: String
    public let title: String
    public let paths: [String]
    public let clearing: Clearing
    /// Executable names whose running processes use this cache.
    public let users: [String]
    public let note: String?

    public static func definitions(home: URL) -> [ToolCache] {
        func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }
        let caches = path("Library/Caches")
        return [
            ToolCache(id: "homebrew", title: "Homebrew downloads and old versions", paths: [caches + "/Homebrew"],
                      clearing: .command(tool: "brew", arguments: ["cleanup", "--prune=all"], whileRunning: nil), users: ["brew"], note: nil),
            ToolCache(id: "go-build", title: "Go build cache", paths: [caches + "/go-build"],
                      clearing: .command(tool: "go", arguments: ["clean", "-cache"], whileRunning: nil), users: ["go"], note: nil),
            ToolCache(id: "npm", title: "npm cache", paths: [path(".npm/_cacache")],
                      clearing: .command(tool: "npm", arguments: ["cache", "clean", "--force"], whileRunning: nil), users: ["npm", "npx"], note: nil),
            ToolCache(id: "uv", title: "uv cache", paths: [path(".cache/uv")],
                      clearing: .command(tool: "uv", arguments: ["cache", "clean"], whileRunning: ["cache", "prune"]), users: ["uv", "uvx"],
                      note: "While uv or uvx runs, only unused entries are pruned."),
            ToolCache(id: "pnpm", title: "pnpm store", paths: [path("Library/pnpm/store")],
                      clearing: .command(tool: "pnpm", arguments: ["store", "prune"], whileRunning: nil), users: ["pnpm"], note: nil),
            ToolCache(id: "yarn", title: "Yarn cache", paths: [caches + "/Yarn"],
                      clearing: .command(tool: "yarn", arguments: ["cache", "clean"], whileRunning: nil), users: ["yarn"], note: nil),
            ToolCache(id: "pip", title: "pip cache", paths: [caches + "/pip"],
                      clearing: .command(tool: "pip3", arguments: ["cache", "purge"], whileRunning: nil), users: ["pip", "pip3"], note: nil),
            ToolCache(id: "playwright", title: "Older Playwright browsers", paths: [caches + "/ms-playwright"],
                      clearing: .playwrightOldRevisions, users: [], note: "The newest revision of each browser is kept."),
            ToolCache(id: "go-modules", title: "Go module downloads", paths: [path("go/pkg/mod")],
                      clearing: .command(tool: "go", arguments: ["clean", "-modcache"], whileRunning: nil), users: ["go", "gopls"],
                      note: "Modules download again on the next build."),
            ToolCache(id: "cargo-registry", title: "Cargo registry and Git checkouts",
                      paths: ["registry/cache", "registry/src", "git/checkouts", "git/db"].map { path(".cargo/" + $0) },
                      clearing: .trash(subpaths: []), users: ["cargo", "rustc", "rust-analyzer"],
                      note: "Crates download again on the next build; ~/.cargo/bin stays.")
        ]
    }
}

public struct ToolCacheStatus: Identifiable, Equatable, Sendable {
    public var id: String { cache.id }
    public let cache: ToolCache
    public let sizeBytes: UInt64
    /// Why it cannot be cleared now, or nil when it can.
    public let blocker: String?
    public let toolPath: String?
}

public enum ToolCacheManager {
    static func searchPath(home: URL) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path,
         home.appendingPathComponent(".cargo/bin").path, home.appendingPathComponent("go/bin").path,
         "/usr/local/go/bin", "/usr/bin", "/bin"]
    }

    static func locate(_ tool: String, home: URL, fileManager: FileManager) -> String? {
        searchPath(home: home).map { ($0 as NSString).appendingPathComponent(tool) }.first(where: fileManager.isExecutableFile(atPath:))
    }

    /// Executable paths of running processes; nil when they could not be read.
    public static func runningExecutables(runner: SoftwareCommandRunning) -> [String]? {
        guard let result = try? runner.run(SoftwareCommand("/bin/ps", arguments: ["-axo", "comm="])), result.succeeded else { return nil }
        return result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func status(environment: MaintenanceStepEnvironment, caches: [ToolCache]? = nil) -> [ToolCacheStatus] {
        let running = runningExecutables(runner: environment.runner)
        let names = Set((running ?? []).map { ($0 as NSString).lastPathComponent })
        return (caches ?? ToolCache.definitions(home: environment.home)).compactMap { cache in
            let existing = cache.paths.filter { environment.fileManager.fileExists(atPath: $0) }
            guard !existing.isEmpty else { return nil }
            let size = existing.reduce(UInt64(0)) {
                $0 + ArtifactInspector.inspect($1, checkLocalConfiguration: false, fileManager: environment.fileManager).sizeBytes
            }
            var tool: String?
            var blocker: String?
            if case let .command(name, _, whileRunning) = cache.clearing {
                tool = locate(name, home: environment.home, fileManager: environment.fileManager)
                if tool == nil { blocker = "\(name) is not installed in a standard location" }
                if blocker == nil, whileRunning == nil, let user = cache.users.first(where: names.contains) { blocker = "\(user) is running" }
            } else if cache.id == "playwright" {
                if (running ?? []).contains(where: { $0.contains("/ms-playwright/") }) { blocker = "a Playwright browser is running" }
            } else if let user = cache.users.first(where: names.contains) {
                blocker = "\(user) is running"
            }
            if running == nil { blocker = "running programs could not be listed" }
            if size == 0, blocker == nil { blocker = "it is empty" }
            return ToolCacheStatus(cache: cache, sizeBytes: size, blocker: blocker, toolPath: tool)
        }
    }

    /// Clears one cache after rechecking that nothing using it runs. Returns the measured size after.
    public static func clear(_ cacheID: String, environment: MaintenanceStepEnvironment) -> Result<UInt64, MaintenanceError> {
        guard let current = status(environment: environment).first(where: { $0.cache.id == cacheID }) else {
            return .failure(.inspectionFailed("the cache no longer exists"))
        }
        if let blocker = current.blocker { return .failure(.changedSinceInspection("\(current.cache.title) (\(blocker))")) }
        let running = Set((runningExecutables(runner: environment.runner) ?? []).map { ($0 as NSString).lastPathComponent })
        switch current.cache.clearing {
        case let .command(_, arguments, whileRunning):
            guard let tool = current.toolPath else { return .failure(.inspectionFailed("the tool is missing")) }
            let users = current.cache.users.filter(running.contains)
            let effective = users.isEmpty ? arguments : (whileRunning ?? arguments)
            let environmentPath = searchPath(home: environment.home).joined(separator: ":")
            let command = SoftwareCommand(tool, arguments: effective, environment: ["PATH": environmentPath, "HOMEBREW_NO_AUTO_UPDATE": "1", "NO_COLOR": "1"])
            do {
                let result = try environment.runner.run(command)
                guard result.succeeded else {
                    return .failure(.inspectionFailed("\(command.displayString) exited with status \(result.status): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            } catch {
                return .failure(.inspectionFailed(error.localizedDescription))
            }
        case .trash:
            for path in current.cache.paths where environment.fileManager.fileExists(atPath: path) {
                do { try environment.trash(URL(fileURLWithPath: path)) } catch {
                    return .failure(.trashFailed(path, error.localizedDescription))
                }
            }
        case .playwrightOldRevisions:
            for path in playwrightOldRevisions(root: current.cache.paths[0], fileManager: environment.fileManager) {
                do { try environment.trash(URL(fileURLWithPath: path)) } catch {
                    return .failure(.trashFailed(path, error.localizedDescription))
                }
            }
        }
        let after = status(environment: environment).first { $0.cache.id == cacheID }?.sizeBytes ?? 0
        return .success(after)
    }

    /// `chromium-1140` and `chromium-1155` are revisions of one browser; all but the newest go.
    public static func playwrightOldRevisions(root: String, fileManager: FileManager) -> [String] {
        let children = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
        var newest: [String: (Int, String)] = [:]
        var all: [(String, Int, String)] = []
        for child in children {
            guard let dash = child.lastIndex(of: "-"), let revision = Int(child[child.index(after: dash)...]) else { continue }
            let browser = String(child[..<dash])
            all.append((browser, revision, child))
            if (newest[browser]?.0 ?? Int.min) < revision { newest[browser] = (revision, child) }
        }
        return all.filter { newest[$0.0]?.1 != $0.2 }.map { (root as NSString).appendingPathComponent($0.2) }.sorted()
    }
}

// MARK: - Trash

public enum TrashBin {
    static func finder(_ script: String) -> SoftwareCommand {
        SoftwareCommand("/usr/bin/osascript", arguments: ["-e", script])
    }

    /// The number of items in the Trash, as Finder reports it.
    public static func itemCount(runner: SoftwareCommandRunning) throws -> Int {
        let result = try runner.run(finder("tell application \"Finder\" to count items of trash"))
        guard result.succeeded, let count = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MaintenanceError.inspectionFailed(automationMessage(result.error))
        }
        return count
    }

    /// Empties the Trash through Finder. A timeout on a large Trash is not a failure; the count is
    /// rechecked until it reaches zero or the deadline passes.
    public static func empty(runner: SoftwareCommandRunning, deadline: TimeInterval = 600, pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> Int {
        let result = try runner.run(finder("with timeout of 600 seconds\ntell application \"Finder\" to empty trash\nend timeout"))
        if !result.succeeded, !result.error.contains("-1712") {
            throw MaintenanceError.inspectionFailed(automationMessage(result.error))
        }
        let start = Date()
        var remaining = try itemCount(runner: runner)
        while remaining > 0, Date().timeIntervalSince(start) < deadline {
            pause(5)
            remaining = try itemCount(runner: runner)
        }
        return remaining
    }

    public static func automationMessage(_ error: String) -> String {
        if error.contains("-1743") || error.localizedCaseInsensitiveContains("not authorized") {
            return "macOS denied KillSwitch permission to control Finder. Allow it in System Settings > Privacy & Security > Automation."
        }
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Finder did not respond." : "Finder reported: \(trimmed)"
    }
}
