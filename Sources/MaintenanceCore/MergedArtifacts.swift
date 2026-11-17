import Darwin
import Foundation
import SoftwareInventoryCore

public enum MergedArtifactKind: String, Codable, CaseIterable, Sendable {
    case installer, installerArchive, stagedApplication, dependencies, buildOutput, testOutput

    public var title: String {
        switch self {
        case .installer: return "Installer"
        case .installerArchive: return "Installer archive"
        case .stagedApplication: return "Staged app"
        case .dependencies: return "Dependencies"
        case .buildOutput: return "Build output"
        case .testOutput: return "Test output"
        }
    }

    /// Dependency and Rust compiler output can ship certificates or dotfiles that are not local configuration.
    func checksLocalConfiguration(name: String) -> Bool { self != .dependencies && name != "target" }

    /// Classifies a wholly ignored directory by name and, for `target` and `build`, its build system.
    public static func directoryKind(name: String, path: String, fileManager: FileManager = .default) -> MergedArtifactKind? {
        switch name {
        case "node_modules": return .dependencies
        case "dist", "dist-electron": return .buildOutput
        case "coverage", "test-results": return .testOutput
        case "target":
            let parent = (path as NSString).deletingLastPathComponent
            return fileManager.fileExists(atPath: (parent as NSString).appendingPathComponent("Cargo.toml")) ? .buildOutput : nil
        case "build":
            return fileManager.fileExists(atPath: (path as NSString).appendingPathComponent("CMakeCache.txt")) ? .buildOutput : nil
        default: return nil
        }
    }
}

public enum ArtifactOwner: Codable, Equatable, Sendable {
    case worktree(path: String, head: String, branch: String)
    case session(directory: String, branch: String)

    public var path: String {
        switch self {
        case .worktree(let path, _, _): return path
        case .session(let directory, _): return directory
        }
    }
}

public struct MergedArtifact: Identifiable, Codable, Equatable, Sendable {
    public var id: String { path }

    public let path: String
    public let kind: MergedArtifactKind
    public let sizeBytes: UInt64
    public let repository: String
    public let pullRequest: Int
    public let pullRequestURL: String?
    public let owner: ArtifactOwner
    public let identity: FileIdentity
    /// The attached image's whole-disk device to eject normally before trashing.
    public let ejectDevice: String?
}

public struct MaintenanceFinding: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(path)|\(reason)" }
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct WorktreeCandidate: Identifiable, Codable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let mainCheckout: String
    public let repository: String
    public let pullRequest: Int
    public let head: String
    public let branch: String
}

public struct SessionCandidate: Identifiable, Codable, Equatable, Sendable {
    public var id: String { directory }
    public let directory: String
    public let repository: String
    public let pullRequest: Int
}

public struct MergedArtifactPlan: Codable, Equatable, Sendable {
    public var createdAt: Date
    public var roots: [String] = []
    public var artifacts: [MergedArtifact] = []
    public var protected: [MaintenanceFinding] = []
    public var skipped: [MaintenanceFinding] = []
    public var worktreeCandidates: [WorktreeCandidate] = []
    public var sessionCandidates: [SessionCandidate] = []
    public var errors: [String] = []
    /// False when an inspection failed and the plan was cut short.
    public var isComplete = true

    public var totalBytes: UInt64 { artifacts.reduce(0) { $0 + $1.sizeBytes } }
}

public struct MaintenanceApplyResult: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    public var trashed: [MergedArtifact] = []
    public var kept: [MaintenanceFinding] = []
    public var ejected: [String] = []
    public var errors: [String] = []
    public var freeBytesBefore: Int64?
    public var freeBytesAfter: Int64?

    public var trashedBytes: UInt64 { trashed.reduce(0) { $0 + $1.sizeBytes } }
    public var freeSpaceChange: Int64? {
        guard let freeBytesBefore, let freeBytesAfter else { return nil }
        return freeBytesAfter - freeBytesBefore
    }
}

/// Finds generated artifacts of confirmed merged pull requests in agent sessions and worktrees.
/// Every step fails closed: anything active, unverifiable, or changed is kept and reported.
public final class MergedArtifactPlanner {
    public struct Environment {
        public var runner: SoftwareCommandRunning
        public var home: URL
        public var now: () -> Date
        public var isProcessAlive: (Int32) -> Bool
        public var trash: MaintenanceTrashMover
        public var gitExecutable: String
        public var ghExecutable: String?
        public var ownExecutable: String
        public var userID: UInt32
        public var sessionQuietPeriod: TimeInterval
        public var gitQuietPeriod: TimeInterval
        public var fileManager: FileManager

        public init(
            runner: SoftwareCommandRunning = NativeSoftwareCommandRunner(),
            home: URL = FileManager.default.homeDirectoryForCurrentUser,
            now: @escaping () -> Date = { Date() },
            isProcessAlive: @escaping (Int32) -> Bool = AgentSessionRegistry.isProcessAlive,
            trash: @escaping MaintenanceTrashMover = MaintenanceTrash.system,
            gitExecutable: String = "/usr/bin/git",
            ghExecutable: String? = PullRequestVerifier.locate(),
            ownExecutable: String = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "",
            userID: UInt32 = getuid(),
            sessionQuietPeriod: TimeInterval = 15 * 60,
            gitQuietPeriod: TimeInterval = 60 * 60,
            fileManager: FileManager = .default
        ) {
            self.runner = runner
            self.home = home
            self.now = now
            self.isProcessAlive = isProcessAlive
            self.trash = trash
            self.gitExecutable = gitExecutable
            self.ghExecutable = ghExecutable
            self.ownExecutable = ownExecutable
            self.userID = userID
            self.sessionQuietPeriod = sessionQuietPeriod
            self.gitQuietPeriod = gitQuietPeriod
            self.fileManager = fileManager
        }
    }

    public static let preservedNamePatterns = ["prewarm"]
    private static let maximumSessionScanDepth = 4

    private let roots: [String]
    private let environment: Environment
    private let git: GitInspector
    private let github: PullRequestVerifier
    private var pullRequestCache: [String: Result<[PullRequestRecord], Error>] = [:]
    private var githubFailure: String?

    public init(roots: [String], environment: Environment = Environment()) {
        self.roots = roots
        self.environment = environment
        git = GitInspector(runner: environment.runner, executable: environment.gitExecutable)
        github = PullRequestVerifier(runner: environment.runner, executable: environment.ghExecutable)
    }

    private var defaultSessionRoot: String { environment.home.appendingPathComponent(".copilot/session-state").path }

    // MARK: Plan

    public func plan() -> MergedArtifactPlan {
        var plan = MergedArtifactPlan(createdAt: environment.now())
        pullRequestCache.removeAll()
        githubFailure = nil
        var validRoots: [String] = []
        for root in roots {
            do {
                validRoots.append(try MaintenanceSettings.validateRoot(root, home: environment.home, fileManager: environment.fileManager))
            } catch {
                plan.skipped.append(MaintenanceFinding(path: root, reason: error.localizedDescription))
            }
        }
        plan.roots = validRoots
        let usage: ProcessUsageSnapshot
        let images: [AttachedDiskImage]
        do {
            usage = try ProcessUsageReader.read(runner: environment.runner)
            images = try DiskImageInspector.read(runner: environment.runner)
        } catch {
            plan.errors.append(error.localizedDescription)
            plan.isComplete = false
            return plan
        }
        let sessions = loadSessions(roots: validRoots, warnings: &plan.errors)

        for checkout in discoverCheckouts(roots: validRoots) {
            inspectCheckout(checkout, sessions: sessions, usage: usage, plan: &plan)
        }
        for session in sessions where validRoots.contains(where: { MaintenancePath.isDescendant(session.directory, of: $0, orEqual: false) }) {
            inspectSession(session, usage: usage, plan: &plan)
        }
        applyDiskImageRules(images: images, usage: usage, plan: &plan)
        if let githubFailure {
            plan.errors.append(githubFailure)
            plan.isComplete = false
        }
        plan.artifacts.sort { $0.sizeBytes > $1.sizeBytes }
        return plan
    }

    private func loadSessions(roots: [String], warnings: inout [String]) -> [AgentSession] {
        var sessionRoots = Set(roots)
        sessionRoots.insert(MaintenancePath.resolved(defaultSessionRoot))
        var sessions: [AgentSession] = []
        for root in sessionRoots.sorted() {
            let loaded = AgentSessionRegistry.load(root: root, isProcessAlive: environment.isProcessAlive, fileManager: environment.fileManager)
            sessions += loaded.sessions
            warnings += loaded.warnings
        }
        return sessions
    }

    func discoverCheckouts(roots: [String]) -> [String] {
        CheckoutDiscovery.find(roots: roots, fileManager: environment.fileManager)
    }

    private func sessions(for workspace: String, in sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { session in
            session.workspacePaths.contains { MaintenancePath.isDescendant($0, of: workspace) || MaintenancePath.isDescendant(workspace, of: $0) }
        }
    }

    /// Why a workspace must be left alone right now, or nil.
    private func workspaceActivity(_ path: String, sessions related: [AgentSession], usage: ProcessUsageSnapshot) -> String? {
        if let reason = related.lazy.compactMap({ session in
            session.activityReason(now: self.environment.now(), quietPeriod: self.environment.sessionQuietPeriod).map {
                "session \(session.sessionID ?? (session.directory as NSString).lastPathComponent) is protected because \($0)"
            }
        }).first {
            return reason
        }
        if !usage.processes(workingIn: path).isEmpty { return "a process is working in it" }
        // Mounted images are judged by the disk image rules, so their helpers do not mark the workspace active.
        if usage.isOpen(path, ignoring: ProcessUsageSnapshot.diskImageHelpers) { return "a process has files open in it" }
        if !environment.ownExecutable.isEmpty, MaintenancePath.isDescendant(MaintenancePath.resolved(environment.ownExecutable), of: MaintenancePath.resolved(path)) {
            return "KillSwitch itself runs from it"
        }
        return nil
    }

    private func inspectCheckout(_ path: String, sessions allSessions: [AgentSession], usage: ProcessUsageSnapshot, plan: inout MergedArtifactPlan) {
        if MaintenancePath.isInDownloads(path, home: environment.home) { return }
        let name = (path as NSString).lastPathComponent.lowercased()
        if Self.preservedNamePatterns.contains(where: name.contains) {
            plan.protected.append(MaintenanceFinding(path: path, reason: "reserved pre-warmed worktree"))
            return
        }
        let related = sessions(for: path, in: allSessions)
        if let reason = workspaceActivity(path, sessions: related, usage: usage) {
            plan.protected.append(MaintenanceFinding(path: path, reason: reason))
            return
        }
        let state: GitCheckoutState
        do {
            state = try git.state(at: path)
        } catch {
            plan.skipped.append(MaintenanceFinding(path: path, reason: error.localizedDescription))
            return
        }
        if let operation = state.operationInProgress {
            plan.protected.append(MaintenanceFinding(path: path, reason: "\(operation) is in progress"))
            return
        }
        if let recent = recentGitActivity(state) {
            plan.protected.append(MaintenanceFinding(path: path, reason: recent))
            return
        }
        guard state.isClean else {
            plan.protected.append(MaintenanceFinding(path: path, reason: "it has uncommitted or untracked changes"))
            return
        }
        guard let branch = state.branch else {
            plan.skipped.append(MaintenanceFinding(path: path, reason: "detached HEAD; its pull request cannot be identified"))
            return
        }
        guard let repository = state.repository else {
            plan.skipped.append(MaintenanceFinding(path: path, reason: "no GitHub origin remote"))
            return
        }
        guard let verdict = verdict(repository: repository, branch: branch, head: state.head, path: path, plan: &plan) else { return }
        guard let pr = verdict.mergedRecord else {
            plan.skipped.append(MaintenanceFinding(path: path, reason: verdict.explanation))
            return
        }
        let owner = ArtifactOwner.worktree(path: state.topLevel, head: state.head, branch: branch)
        do {
            for entry in try git.ignoredEntries(at: state.topLevel) {
                classify(entry: entry, topLevel: state.topLevel, repository: repository, pr: pr, owner: owner, plan: &plan)
            }
        } catch {
            plan.skipped.append(MaintenanceFinding(path: path, reason: error.localizedDescription))
            return
        }
        if state.isLinkedWorktree {
            plan.worktreeCandidates.append(WorktreeCandidate(
                path: state.topLevel, mainCheckout: state.mainCheckout, repository: repository.description,
                pullRequest: pr.number, head: state.head, branch: branch
            ))
        }
    }

    private func recentGitActivity(_ state: GitCheckoutState) -> String? {
        let newest = ["HEAD", "index", "logs/HEAD"]
            .compactMap { FileIdentity.read((state.gitDirectory as NSString).appendingPathComponent($0))?.modified }
            .max()
        guard let newest else { return nil }
        let age = environment.now().timeIntervalSince1970 - newest
        return age < environment.gitQuietPeriod ? "Git activity \(max(0, Int(age / 60))) minute(s) ago" : nil
    }

    /// Looks up PRs once per repository and branch. After a GitHub failure every later
    /// lookup is skipped, rather than trusting stale or partial state.
    private func verdict(repository: GitHubRepository, branch: String, head: String?, path: String, plan: inout MergedArtifactPlan) -> PullRequestVerdict? {
        if githubFailure != nil {
            plan.skipped.append(MaintenanceFinding(path: path, reason: "GitHub verification is unavailable for this run"))
            return nil
        }
        let key = "\(repository)#\(branch)"
        let result = pullRequestCache[key] ?? Result { try github.pullRequests(repository: repository, branch: branch) }
        pullRequestCache[key] = result
        switch result {
        case .success(let records):
            return PullRequestVerdict.evaluate(records, headSHA: head)
        case .failure(let error):
            githubFailure = error.localizedDescription
            plan.skipped.append(MaintenanceFinding(path: path, reason: "GitHub verification failed"))
            return nil
        }
    }

    private func classify(
        entry: String, topLevel: String, repository: GitHubRepository, pr: PullRequestRecord,
        owner: ArtifactOwner, plan: inout MergedArtifactPlan
    ) {
        let isDirectory = entry.hasSuffix("/")
        let relative = isDirectory ? String(entry.dropLast()) : entry
        let components = relative.split(separator: "/")
        guard !components.contains(".git"), let name = components.last.map(String.init) else { return }
        let path = (topLevel as NSString).appendingPathComponent(relative)
        if isDirectory {
            if let kind = MergedArtifactKind.directoryKind(name: name, path: path, fileManager: environment.fileManager) {
                addCandidate(path: path, kind: kind, root: topLevel, repository: repository, pr: pr, owner: owner, plan: &plan)
            } else {
                for (found, kind) in findInstallers(in: path, relativeTo: topLevel) {
                    addCandidate(path: found, kind: kind, root: topLevel, repository: repository, pr: pr, owner: owner, plan: &plan)
                }
            }
        } else if let kind = fileKind(path: path, name: name) {
            addCandidate(path: path, kind: kind, root: topLevel, repository: repository, pr: pr, owner: owner, plan: &plan)
        }
    }

    private func fileKind(path: String, name: String) -> MergedArtifactKind? {
        if ArtifactInspector.isInstaller(name) { return .installer }
        if ArtifactInspector.archiveKind(name) != nil, ArtifactInspector.archiveContainsApplication(path, runner: environment.runner) {
            return .installerArchive
        }
        return nil
    }

    /// Installers, installer archives, and staged apps inside an ignored directory that is not itself eligible.
    private func findInstallers(in directory: String, relativeTo root: String, maximumDepth: Int = 4) -> [(String, MergedArtifactKind)] {
        var found: [(String, MergedArtifactKind)] = []
        var queue: [(String, Int)] = [(directory, 0)]
        let skipped: Set<String> = [".git", "node_modules", "vendor", ".venv", "Pods", ".gradle", ".m2", ".yarn", ".terraform", "DerivedData", "cache", ".cache"]
        while let (current, depth) = queue.popLast() {
            guard let children = try? environment.fileManager.contentsOfDirectory(atPath: current) else { continue }
            for child in children where !skipped.contains(child) {
                let path = (current as NSString).appendingPathComponent(child)
                guard let identity = FileIdentity.read(path), !identity.isSymbolicLink else { continue }
                if identity.isDirectory {
                    if child.lowercased().hasSuffix(".app") {
                        if let relative = MaintenancePath.relative(path, to: root), ArtifactInspector.isStagedApplication(relativePath: relative) {
                            found.append((path, .stagedApplication))
                        }
                    } else if depth < maximumDepth {
                        queue.append((path, depth + 1))
                    }
                } else if let kind = fileKind(path: path, name: child) {
                    found.append((path, kind))
                }
            }
        }
        return found
    }

    private func addCandidate(
        path: String, kind: MergedArtifactKind, root: String, repository: GitHubRepository, pr: PullRequestRecord,
        owner: ArtifactOwner, plan: inout MergedArtifactPlan
    ) {
        if let reason = safetyFailure(path: path, kind: kind, root: root, owner: owner) {
            plan.protected.append(MaintenanceFinding(path: path, reason: reason))
            return
        }
        guard let identity = FileIdentity.read(path) else { return }
        let inspection = ArtifactInspector.inspect(
            path, checkLocalConfiguration: kind.checksLocalConfiguration(name: (path as NSString).lastPathComponent),
            fileManager: environment.fileManager
        )
        if !inspection.nestedGitPaths.isEmpty {
            plan.protected.append(MaintenanceFinding(path: path, reason: "it contains a nested Git checkout that cannot be proven pristine"))
            return
        }
        if let config = inspection.localConfigurationPaths.first {
            plan.protected.append(MaintenanceFinding(path: path, reason: "it contains local configuration (\((config as NSString).lastPathComponent))"))
            return
        }
        if inspection.unreadableCount > 0 {
            plan.protected.append(MaintenanceFinding(path: path, reason: "\(inspection.unreadableCount) item(s) inside could not be read"))
            return
        }
        plan.artifacts.append(MergedArtifact(
            path: path, kind: kind, sizeBytes: inspection.sizeBytes, repository: repository.description,
            pullRequest: pr.number, pullRequestURL: pr.htmlURL, owner: owner, identity: identity, ejectDevice: nil
        ))
    }

    /// Path-level safety: user-owned, not a link, inside its owner without a link escape,
    /// outside `.git` and `~/Downloads`, and, in a checkout, holding no tracked files.
    private func safetyFailure(path: String, kind: MergedArtifactKind, root: String, owner: ArtifactOwner) -> String? {
        guard let identity = FileIdentity.read(path) else { return "it disappeared during inspection" }
        if identity.isSymbolicLink { return "it is a symbolic link" }
        if identity.owner != environment.userID { return "it is owned by another user" }
        if MaintenancePath.isInDownloads(path, home: environment.home) { return "~/Downloads is never cleaned here" }
        let resolved = MaintenancePath.resolved(path)
        guard MaintenancePath.isDescendant(resolved, of: MaintenancePath.resolved(root), orEqual: false) else {
            return "its resolved path escapes \(root)"
        }
        if resolved.split(separator: "/").contains(".git") { return "it is inside Git metadata" }
        if case .worktree = owner {
            guard let relative = MaintenancePath.relative(path, to: root) else { return "its location could not be verified" }
            do {
                if try git.hasTrackedFiles(relative, topLevel: root) { return "Git tracks files inside it" }
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }

    private func inspectSession(_ session: AgentSession, usage: ProcessUsageSnapshot, plan: inout MergedArtifactPlan) {
        let files = (session.directory as NSString).appendingPathComponent("files")
        guard environment.fileManager.fileExists(atPath: files) else { return }
        let found = findInstallers(in: files, relativeTo: files, maximumDepth: Self.maximumSessionScanDepth)
            .filter { $0.1 != .stagedApplication || ArtifactInspector.isStagedApplication(relativePath: MaintenancePath.relative($0.0, to: files) ?? "") }
        guard !found.isEmpty else { return }
        if let reason = session.activityReason(now: environment.now(), quietPeriod: environment.sessionQuietPeriod) {
            plan.protected.append(MaintenanceFinding(path: session.directory, reason: "session artifacts kept because \(reason)"))
            return
        }
        if let workspace = session.workspacePaths.first(where: { environment.fileManager.fileExists(atPath: $0) }),
           let reason = workspaceActivity(workspace, sessions: [], usage: usage) {
            plan.protected.append(MaintenanceFinding(path: session.directory, reason: "its workspace is in use: \(reason)"))
            return
        }
        guard let repository = session.repository.flatMap(GitHubRepository.init(slug:)), let branch = session.branch else {
            plan.skipped.append(MaintenanceFinding(path: session.directory, reason: "no recorded GitHub repository and branch"))
            return
        }
        guard let verdict = verdict(repository: repository, branch: branch, head: nil, path: session.directory, plan: &plan) else { return }
        guard let pr = verdict.mergedRecord, let mergedAt = pr.mergedAt else {
            plan.skipped.append(MaintenanceFinding(path: session.directory, reason: "recorded branch \(branch): \(verdict.explanation)"))
            return
        }
        let owner = ArtifactOwner.session(directory: session.directory, branch: branch)
        for (path, kind) in found {
            // An artifact newer than the merge may come from later, unmerged work on a reused branch.
            guard let identity = FileIdentity.read(path), identity.modified <= mergedAt.timeIntervalSince1970 + 3_600 else {
                plan.skipped.append(MaintenanceFinding(path: path, reason: "it was created after PR #\(pr.number) merged"))
                continue
            }
            addCandidate(path: path, kind: kind, root: session.directory, repository: repository, pr: pr, owner: owner, plan: &plan)
        }
        if !session.workspacePaths.contains(where: { environment.fileManager.fileExists(atPath: $0) }) {
            plan.sessionCandidates.append(SessionCandidate(directory: session.directory, repository: repository.description, pullRequest: pr.number))
        }
    }

    /// Mounted installer images are kept unless a normal eject is safe: the image belongs to
    /// this user, is read-only, and nothing uses its volume. Moved backing files are ambiguous.
    private func applyDiskImageRules(images: [AttachedDiskImage], usage: ProcessUsageSnapshot, plan: inout MergedArtifactPlan) {
        let missingNames = Set(images.filter { !environment.fileManager.fileExists(atPath: $0.imagePath) }
            .map { ($0.imagePath as NSString).lastPathComponent })
        var kept: [MergedArtifact] = []
        for artifact in plan.artifacts {
            let resolved = MaintenancePath.resolved(artifact.path)
            let attached = images.first { MaintenancePath.resolved($0.imagePath) == resolved }
            if artifact.kind == .installer, let image = attached {
                if let reason = ejectRefusal(image, usage: usage) {
                    plan.protected.append(MaintenanceFinding(path: artifact.path, reason: "it is mounted and \(reason)"))
                } else {
                    kept.append(MergedArtifact(
                        path: artifact.path, kind: artifact.kind, sizeBytes: artifact.sizeBytes, repository: artifact.repository,
                        pullRequest: artifact.pullRequest, pullRequestURL: artifact.pullRequestURL, owner: artifact.owner,
                        identity: artifact.identity, ejectDevice: image.wholeDisk
                    ))
                }
                continue
            }
            if artifact.kind == .installer, missingNames.contains((artifact.path as NSString).lastPathComponent) {
                plan.protected.append(MaintenanceFinding(path: artifact.path, reason: "it may back a mounted image whose file moved"))
                continue
            }
            if usage.isOpen(artifact.path) {
                plan.protected.append(MaintenanceFinding(path: artifact.path, reason: "a process has it open"))
                continue
            }
            kept.append(artifact)
        }
        plan.artifacts = kept
    }

    private func ejectRefusal(_ image: AttachedDiskImage, usage: ProcessUsageSnapshot) -> String? {
        if image.ownerUID != environment.userID { return "is attached by another user" }
        if image.isWriteable { return "is attached writable" }
        if image.wholeDisk == nil { return "its device could not be identified" }
        if image.mountPoints.contains(where: usage.isInUse) { return "files on its volume are in use" }
        if usage.isOpen(image.imagePath, ignoring: ProcessUsageSnapshot.diskImageHelpers) { return "another process has the image open" }
        return nil
    }

    // MARK: Apply

    /// Rechecks every manifest entry immediately before moving it to the Trash.
    public func apply(_ plan: MergedArtifactPlan) -> MaintenanceApplyResult {
        var result = MaintenanceApplyResult(startedAt: environment.now(), finishedAt: environment.now())
        result.freeBytesBefore = ArtifactInspector.availableBytes(at: environment.home.path)
        let usage: ProcessUsageSnapshot
        let sessions: [AgentSession]
        do {
            usage = try ProcessUsageReader.read(runner: environment.runner)
            _ = try DiskImageInspector.read(runner: environment.runner)
            var warnings: [String] = []
            sessions = loadSessions(roots: plan.roots, warnings: &warnings)
        } catch {
            result.errors.append(error.localizedDescription)
            result.kept = plan.artifacts.map { MaintenanceFinding(path: $0.path, reason: "nothing was removed because inspection failed") }
            result.finishedAt = environment.now()
            return result
        }
        var verifiedOwners: [String: String?] = [:]
        for artifact in plan.artifacts {
            let ownerPath = artifact.owner.path
            if verifiedOwners[ownerPath] == nil {
                verifiedOwners[ownerPath] = .some(ownerRecheck(artifact.owner, sessions: sessions, usage: usage))
            }
            if let reason = verifiedOwners[ownerPath] ?? nil {
                result.kept.append(MaintenanceFinding(path: artifact.path, reason: reason))
                continue
            }
            if let reason = artifactRecheck(artifact, usage: usage) {
                result.kept.append(MaintenanceFinding(path: artifact.path, reason: reason))
                continue
            }
            if let device = artifact.ejectDevice {
                guard eject(device, artifact: artifact, result: &result) else { continue }
            }
            do {
                try environment.trash(URL(fileURLWithPath: artifact.path))
                result.trashed.append(artifact)
            } catch {
                result.errors.append(MaintenanceError.trashFailed(artifact.path, error.localizedDescription).localizedDescription)
            }
        }
        verifySources(after: result.trashed, result: &result)
        result.freeBytesAfter = ArtifactInspector.availableBytes(at: environment.home.path)
        result.finishedAt = environment.now()
        return result
    }

    private func ownerRecheck(_ owner: ArtifactOwner, sessions: [AgentSession], usage: ProcessUsageSnapshot) -> String? {
        switch owner {
        case let .worktree(path, head, branch):
            if let reason = workspaceActivity(path, sessions: self.sessions(for: path, in: sessions), usage: usage) { return reason }
            guard let state = try? git.state(at: path) else { return "its Git state could not be read again" }
            if state.head != head || state.branch != branch { return "its HEAD or branch changed after inspection" }
            if !state.isClean { return "it now has uncommitted or untracked changes" }
            if let operation = state.operationInProgress { return "\(operation) started" }
            return recentGitActivity(state)
        case let .session(directory, _):
            guard let session = sessions.first(where: { $0.directory == directory }) else { return "its session metadata disappeared" }
            if let reason = session.activityReason(now: environment.now(), quietPeriod: environment.sessionQuietPeriod) {
                return "its session became active: \(reason)"
            }
            if let workspace = session.workspacePaths.first(where: { environment.fileManager.fileExists(atPath: $0) }),
               let reason = workspaceActivity(workspace, sessions: [], usage: usage) {
                return "its workspace is in use: \(reason)"
            }
            return nil
        }
    }

    private func artifactRecheck(_ artifact: MergedArtifact, usage: ProcessUsageSnapshot) -> String? {
        guard artifact.identity.matches(FileIdentity.read(artifact.path)) else {
            return MaintenanceError.changedSinceInspection(artifact.path).localizedDescription
        }
        if let reason = safetyFailure(path: artifact.path, kind: artifact.kind, root: artifact.owner.path, owner: artifact.owner) { return reason }
        if case .worktree(let root, _, _) = artifact.owner, let relative = MaintenancePath.relative(artifact.path, to: root) {
            guard (try? git.isIgnored(relative, topLevel: root)) == true else { return "Git no longer ignores it" }
        }
        let ignoring = artifact.ejectDevice == nil ? Set<String>() : ProcessUsageSnapshot.diskImageHelpers
        if usage.isOpen(artifact.path, ignoring: ignoring) { return "a process has it open" }
        return nil
    }

    private func eject(_ device: String, artifact: MergedArtifact, result: inout MaintenanceApplyResult) -> Bool {
        do {
            let freshUsage = try ProcessUsageReader.read(runner: environment.runner)
            let images = try DiskImageInspector.read(runner: environment.runner)
            guard let image = images.first(where: { $0.wholeDisk == device }),
                  MaintenancePath.resolved(image.imagePath) == MaintenancePath.resolved(artifact.path) else {
                result.kept.append(MaintenanceFinding(path: artifact.path, reason: "its mounted image changed before ejecting"))
                return false
            }
            if let reason = ejectRefusal(image, usage: freshUsage) {
                result.kept.append(MaintenanceFinding(path: artifact.path, reason: "it is mounted and \(reason)"))
                return false
            }
            let detach = try environment.runner.run(DiskImageInspector.detachCommand(device))
            guard detach.succeeded else {
                result.kept.append(MaintenanceFinding(path: artifact.path, reason: "a normal eject failed: \(detach.error.trimmingCharacters(in: .whitespacesAndNewlines))"))
                return false
            }
            let after = try DiskImageInspector.read(runner: environment.runner)
            guard !after.contains(where: { MaintenancePath.resolved($0.imagePath) == MaintenancePath.resolved(artifact.path) }) else {
                result.kept.append(MaintenanceFinding(path: artifact.path, reason: "the image is still attached after ejecting"))
                return false
            }
            result.ejected.append(artifact.path)
            return true
        } catch {
            result.kept.append(MaintenanceFinding(path: artifact.path, reason: "it is mounted and could not be checked: \(error.localizedDescription)"))
            return false
        }
    }

    /// Confirms each touched worktree is still clean at the same HEAD and each session's history remains.
    private func verifySources(after trashed: [MergedArtifact], result: inout MaintenanceApplyResult) {
        var checked = Set<String>()
        for artifact in trashed where checked.insert(artifact.owner.path).inserted {
            switch artifact.owner {
            case let .worktree(path, head, _):
                if let state = try? git.state(at: path), state.isClean, state.head == head { continue }
                result.errors.append("\(path) is no longer clean at its inspected HEAD after cleanup; review it.")
            case .session(let directory, _):
                let history = ["workspace.yaml"].map { (directory as NSString).appendingPathComponent($0) }
                if !history.allSatisfy(environment.fileManager.fileExists(atPath:)) {
                    result.errors.append("\(directory) is missing session metadata after cleanup; review it.")
                }
            }
        }
    }

    // MARK: Worktree removal (approved)

    /// Removes one approved worktree with `git worktree remove`, never forced, after rechecking it.
    public func removeWorktree(_ candidate: WorktreeCandidate) -> Result<String, MaintenanceError> {
        do {
            let usage = try ProcessUsageReader.read(runner: environment.runner)
            var warnings: [String] = []
            let sessions = loadSessions(roots: roots.map { MaintenancePath.expand($0, home: environment.home) }, warnings: &warnings)
            if let reason = ownerRecheck(.worktree(path: candidate.path, head: candidate.head, branch: candidate.branch), sessions: sessions, usage: usage) {
                return .failure(.changedSinceInspection("\(candidate.path) (\(reason))"))
            }
            guard let repository = GitHubRepository(slug: candidate.repository) else {
                return .failure(.inspectionFailed("the recorded repository is invalid"))
            }
            let verdict = PullRequestVerdict.evaluate(try github.pullRequests(repository: repository, branch: candidate.branch), headSHA: candidate.head)
            guard verdict.mergedRecord?.number == candidate.pullRequest else {
                return .failure(.changedSinceInspection("\(candidate.path) (\(verdict.explanation))"))
            }
            let result = try environment.runner.run(git.removeWorktreeCommand(candidate.path, mainCheckout: candidate.mainCheckout))
            guard result.succeeded else {
                return .failure(.gitFailed(result.error.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            guard !environment.fileManager.fileExists(atPath: candidate.path) else {
                return .failure(.gitFailed("\(candidate.path) still exists after git worktree remove"))
            }
            return .success("Removed \(candidate.path) for merged PR #\(candidate.pullRequest).")
        } catch let error as MaintenanceError {
            return .failure(error)
        } catch {
            return .failure(.inspectionFailed(error.localizedDescription))
        }
    }
}

// MARK: - Audit record

public struct MergedArtifactAuditRecord: Encodable {
    struct Removal: Encodable {
        let path: String
        let bytes: UInt64
    }

    struct Repository: Encodable {
        let repository: String
        let pullRequest: Int
        let removed: [Removal]
    }

    let timestamp: Date
    let task = "merged-artifacts"
    let mode: String
    let repositories: [Repository]
    let protected: [MaintenanceFinding]
    let skipped: [MaintenanceFinding]
    let errors: [String]
    let logicalBytes: UInt64
    let freeSpaceChangeBytes: Int64?
    let complete: Bool

    /// A compact record: paths, sizes, and reasons only; never file contents or process arguments.
    public init(mode: String, plan: MergedArtifactPlan, result: MaintenanceApplyResult?) {
        timestamp = result?.finishedAt ?? plan.createdAt
        self.mode = mode
        let removed = result?.trashed ?? []
        let grouped = Dictionary(grouping: removed) { "\($0.repository)#\($0.pullRequest)" }
        repositories = grouped.values.compactMap { items in
            items.first.map { first in
                Repository(repository: first.repository, pullRequest: first.pullRequest,
                           removed: items.map { Removal(path: $0.path, bytes: $0.sizeBytes) })
            }
        }.sorted { $0.repository == $1.repository ? $0.pullRequest < $1.pullRequest : $0.repository < $1.repository }
        protected = plan.protected + (result?.kept ?? [])
        skipped = plan.skipped
        errors = plan.errors + (result?.errors ?? [])
        logicalBytes = result?.trashedBytes ?? plan.totalBytes
        freeSpaceChangeBytes = result?.freeSpaceChange
        complete = plan.isComplete && (result?.errors.isEmpty ?? true)
    }
}
