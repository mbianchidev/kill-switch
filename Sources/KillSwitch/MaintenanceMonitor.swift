import Combine
import Darwin
import Foundation
import MaintenanceCore
import SoftwareInventoryCore
import os

/// Coordinates the Disk cleanup maintenance tools. Every scan builds an exact manifest; nothing is
/// moved until the user confirms, except merged-PR artifacts when the optional schedule is on.
/// Items go to the Trash, and only a separately confirmed Empty Trash frees their space.
@MainActor
final class MaintenanceMonitor: ObservableObject {
#if KILLSWITCH_PERFORMANCE_PROBE
    // The probe never reads or writes the user's maintenance settings or history.
    static let shared = MaintenanceMonitor(
        defaults: UserDefaults(suiteName: "KillSwitch.synthetic-maintenance-\(UUID().uuidString)") ?? UserDefaults()
    )
#else
    static let shared = MaintenanceMonitor()
#endif

    enum Step: String, CaseIterable, Identifiable {
        case mergedArtifacts, archives, diskImages, buildOutput, caches, trash
        var id: Self { self }

        var title: String {
            switch self {
            case .mergedArtifacts: return "Merged PR artifacts"
            case .archives: return "Archives in agent worktrees"
            case .diskImages: return "Installed disk images"
            case .buildOutput: return "Idle build output"
            case .caches: return "Tool caches"
            case .trash: return "Trash"
            }
        }
    }

    @Published private(set) var settings: MaintenanceSettings
    @Published private(set) var settingsWarning: String?
    @Published private(set) var busyStep: Step?
    @Published private(set) var mergedPlan: MergedArtifactPlan?
    @Published private(set) var mergedResult: MaintenanceApplyResult?
    @Published private(set) var archiveScan: TrashScan?
    @Published private(set) var diskImageScan: TrashScan?
    @Published private(set) var buildScan: TrashScan?
    @Published private(set) var lastTrashResult: (step: Step, result: TrashRunResult)?
    @Published private(set) var caches: [ToolCacheStatus]?
    @Published private(set) var trashItemCount: Int?
    @Published private(set) var history: [MaintenanceRunSummary] = []
    @Published private(set) var lastScheduledRun: Date?
    @Published private(set) var message: String?
    @Published private(set) var errorMessage: String?

    var isBusy: Bool { busyStep != nil }
    var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    var auditLogURL: URL { MaintenanceAuditLog.defaultURL(home: home) }

    private let settingsStore: MaintenanceSettingsStore
    private let historyStore: MaintenanceHistoryStore
    private let queue = DispatchQueue(label: "killswitch.maintenance", qos: .utility)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "maintenance")
    private var timer: DispatchSourceTimer?
    private var started = false
    /// Turning the schedule off or stopping revokes this, which stops a running unattended
    /// cleanup before its next move. Explicitly confirmed runs do not use it.
    private let scheduleAuthorization = RunAuthorization()
    /// Bumped when roots change, so scans and plans built for the old roots are discarded.
    private var artifactRootsGeneration = 0
    private var repositoryRootsGeneration = 0

    private init(defaults: UserDefaults = .standard) {
        settingsStore = MaintenanceSettingsStore(defaults: defaults)
        historyStore = MaintenanceHistoryStore(defaults: defaults)
        let loaded = settingsStore.load()
        settings = loaded.settings
        settingsWarning = loaded.warning
        history = historyStore.load()
    }

    /// Starts the optional schedule; it never runs while the schedule is off.
    func start() {
        guard !started else { return }
        started = true
        reschedule()
    }

    func stop() {
        started = false
        scheduleAuthorization.revoke()
        timer?.cancel()
        timer = nil
    }

    func clearMessages() {
        message = nil
        errorMessage = nil
    }

    // MARK: Settings

    func addRoot(_ url: URL, repository: Bool) {
        do {
            let path = try MaintenanceSettings.validateRoot(url.path, home: home)
            var updated = settings
            if repository {
                guard !updated.repositoryRoots.contains(path) else { return }
                updated.repositoryRoots.append(path)
            } else {
                guard !updated.artifactRoots.contains(path) else { return }
                updated.artifactRoots.append(path)
            }
            save(updated)
        } catch {
            report(error.localizedDescription)
        }
    }

    func removeRoot(_ path: String, repository: Bool) {
        var updated = settings
        if repository { updated.repositoryRoots.removeAll { $0 == path } } else { updated.artifactRoots.removeAll { $0 == path } }
        save(updated)
    }

    func resetRoots() {
        var updated = settings
        let defaults = MaintenanceSettings.defaults(home: home)
        updated.artifactRoots = defaults.artifactRoots
        updated.repositoryRoots = defaults.repositoryRoots
        save(updated)
    }

    func setSchedule(enabled: Bool, intervalHours: Int) {
        var updated = settings
        updated.scheduleEnabled = enabled
        updated.scheduleIntervalHours = MaintenanceSettings.scheduleOptions.contains(intervalHours) ? intervalHours : 24
        if !enabled { scheduleAuthorization.revoke() }
        save(updated)
        if started { reschedule() }
    }

    func setIdle(archiveHours: Int? = nil, buildDays: Int? = nil) {
        var updated = settings
        if let archiveHours { updated.archiveIdleHours = max(1, archiveHours) }
        if let buildDays { updated.buildIdleDays = max(1, buildDays) }
        save(updated)
    }

    private func save(_ updated: MaintenanceSettings) {
        do {
            try settingsStore.save(updated)
            if updated.artifactRoots != settings.artifactRoots {
                artifactRootsGeneration += 1
                mergedPlan = nil
                mergedResult = nil
                archiveScan = nil
            }
            if updated.repositoryRoots != settings.repositoryRoots {
                repositoryRootsGeneration += 1
                buildScan = nil
            }
            settings = updated
            settingsWarning = nil
        } catch {
            report("Maintenance settings could not be saved: \(error.localizedDescription)")
        }
    }

    // MARK: Merged artifacts

    func previewMergedArtifacts() {
        let roots = settings.artifactRoots
        let generation = artifactRootsGeneration
        perform(.mergedArtifacts) {
            MergedArtifactPlanner(roots: roots).plan()
        } finish: { monitor, plan in
            guard monitor.artifactRootsGeneration == generation else {
                monitor.message = "Maintenance roots changed during the preview. Preview again."
                return
            }
            monitor.mergedPlan = plan
            monitor.mergedResult = nil
            monitor.message = plan.artifacts.isEmpty
                ? "Nothing is eligible. \(plan.protected.count) protected and \(plan.skipped.count) skipped item(s) are listed below."
                : "\(plan.artifacts.count) artifact(s), \(formatBytes(plan.totalBytes)), can move to the Trash."
        }
    }

    func applyMergedArtifacts() {
        guard let plan = mergedPlan, !plan.artifacts.isEmpty else { return }
        runMergedCleanup(plan: plan, mode: "apply")
    }

    private func runMergedCleanup(plan existing: MergedArtifactPlan?, mode: String) {
        let roots = settings.artifactRoots
        let auditURL = auditLogURL
        let generation = artifactRootsGeneration
        let authorization = scheduleAuthorization
        let token = authorization.current()
        let unattended = mode == "scheduled"
        perform(.mergedArtifacts) {
            let planner = MergedArtifactPlanner(roots: roots)
            let plan = existing ?? planner.plan()
            let result = planner.apply(plan, shouldContinue: { !unattended || authorization.isValid(token) })
            let auditError: String?
            do {
                try MaintenanceAuditLog(url: auditURL).append(MergedArtifactAuditRecord(mode: mode, plan: plan, result: result))
                auditError = nil
            } catch {
                auditError = "The audit record could not be written: \(error.localizedDescription)"
            }
            return (plan, result, auditError)
        } finish: { monitor, output in
            let (plan, result, auditError) = output
            if monitor.artifactRootsGeneration == generation {
                monitor.mergedPlan = plan
                monitor.mergedResult = result
            }
            if mode == "scheduled" { monitor.lastScheduledRun = result.finishedAt }
            monitor.record(MaintenanceRunSummary(
                date: result.finishedAt, task: Step.mergedArtifacts.title, mode: mode, trashedCount: result.trashed.count,
                trashedBytes: result.trashedBytes, protectedCount: plan.protected.count + result.kept.count,
                errorCount: plan.errors.count + result.errors.count + (auditError == nil ? 0 : 1)
            ))
            if let auditError { monitor.report(auditError) }
            monitor.message = Self.summary(result)
        }
    }

    func removeWorktree(_ candidate: WorktreeCandidate) {
        let roots = settings.artifactRoots
        let auditURL = auditLogURL
        perform(.mergedArtifacts) {
            let outcome = MergedArtifactPlanner(roots: roots).removeWorktree(candidate)
            struct Record: Encodable {
                let timestamp: Date
                let task = "approved-worktree-removal"
                let repository: String
                let pullRequest: Int
                let path: String
                let result: String
            }
            let description: String
            switch outcome {
            case .success(let text): description = text
            case .failure(let error): description = "kept: \(error.localizedDescription)"
            }
            let auditError: String?
            do {
                try MaintenanceAuditLog(url: auditURL).append(Record(
                    timestamp: Date(), repository: candidate.repository, pullRequest: candidate.pullRequest, path: candidate.path, result: description
                ))
                auditError = nil
            } catch {
                auditError = "The audit record for this worktree could not be written: \(error.localizedDescription)"
            }
            return (outcome, auditError)
        } finish: { monitor, output in
            let (outcome, auditError) = output
            if let auditError { monitor.report(auditError) }
            switch outcome {
            case .success(let text):
                monitor.message = text
                monitor.mergedPlan?.worktreeCandidates.removeAll { $0.path == candidate.path }
                monitor.mergedPlan?.artifacts.removeAll { $0.owner.path == candidate.path }
            case .failure(let error):
                monitor.report("The worktree was kept: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Skill steps

    func scan(_ step: Step) {
        let settings = settings
        let environment = MaintenanceStepEnvironment()
        let artifactGeneration = artifactRootsGeneration
        let repositoryGeneration = repositoryRootsGeneration
        switch step {
        case .archives:
            perform(step) { ArchiveSweeper.scan(roots: settings.artifactRoots, minimumIdleHours: settings.archiveIdleHours, environment: environment) }
                finish: { monitor, scan in
                    guard monitor.artifactRootsGeneration == artifactGeneration else { return monitor.rootsChanged(step) }
                    monitor.archiveScan = scan
                    monitor.describe(scan, step: step)
                }
        case .diskImages:
            perform(step) { InstalledDiskImageFinder.scan(environment: environment) }
                finish: { $0.diskImageScan = $1; $0.describe($1, step: step) }
        case .buildOutput:
            perform(step) { IdleBuildOutputFinder.scan(repositoryRoots: settings.repositoryRoots, idleDays: settings.buildIdleDays, environment: environment) }
                finish: { monitor, scan in
                    guard monitor.repositoryRootsGeneration == repositoryGeneration else { return monitor.rootsChanged(step) }
                    monitor.buildScan = scan
                    monitor.describe(scan, step: step)
                }
        case .caches:
            perform(step) { ToolCacheManager.status(environment: environment) } finish: { $0.caches = $1 }
        case .trash:
            perform(step) { Result { try TrashBin.itemCount(runner: environment.runner) } } finish: { monitor, result in
                switch result {
                case .success(let count): monitor.trashItemCount = count
                case .failure(let error): monitor.report(error.localizedDescription)
                }
            }
        case .mergedArtifacts:
            previewMergedArtifacts()
        }
    }

    /// Moves a scanned step's candidates to the Trash after rechecking each one.
    func moveToTrash(_ step: Step) {
        let scan: TrashScan?
        switch step {
        case .archives: scan = archiveScan
        case .diskImages: scan = diskImageScan
        case .buildOutput: scan = buildScan
        default: scan = nil
        }
        guard let candidates = scan?.candidates, !candidates.isEmpty else { return }
        let environment = MaintenanceStepEnvironment()
        perform(step) {
            environment.trash(candidates) { step == .archives ? ArchiveSweeper.recheck($0, environment: environment) : nil }
        } finish: { monitor, result in
            monitor.lastTrashResult = (step, result)
            let trashed = Set(result.trashed.map(\.path))
            switch step {
            case .archives: monitor.archiveScan?.candidates.removeAll { trashed.contains($0.path) }
            case .diskImages: monitor.diskImageScan?.candidates.removeAll { trashed.contains($0.path) }
            case .buildOutput: monitor.buildScan?.candidates.removeAll { trashed.contains($0.path) }
            default: break
            }
            monitor.record(MaintenanceRunSummary(
                date: Date(), task: step.title, mode: "apply", trashedCount: result.trashed.count, trashedBytes: result.trashedBytes,
                protectedCount: result.kept.count, errorCount: result.errors.count
            ))
            result.errors.forEach { monitor.report($0) }
            monitor.message = "Moved \(result.trashed.count) item(s), \(formatBytes(result.trashedBytes)), to the Trash; kept \(result.kept.count). Empty the Trash to free the space."
            monitor.trashItemCount = nil
        }
    }

    func clearCache(_ cache: ToolCacheStatus) {
        let environment = MaintenanceStepEnvironment()
        let before = cache.sizeBytes
        perform(.caches) { () -> (Result<[ToolCacheStatus], MaintenanceError>, [ToolCacheStatus]?) in
            let result = ToolCacheManager.clear(cache.id, environment: environment)
            // A successful clear already measured every cache; only a failure needs a fresh read.
            if case .success = result { return (result, nil) }
            return (result, ToolCacheManager.status(environment: environment))
        } finish: { monitor, output in
            switch output.0 {
            case .success(let statuses):
                monitor.caches = statuses
                let after = statuses.first { $0.cache.id == cache.cache.id }?.sizeBytes ?? 0
                let freed = before > after ? before - after : 0
                monitor.message = "\(cache.cache.title): \(formatBytes(freed)) cleared."
                monitor.record(MaintenanceRunSummary(date: Date(), task: cache.cache.title, mode: "apply", trashedCount: 1,
                                                     trashedBytes: freed, protectedCount: 0, errorCount: 0))
            case .failure(let error):
                monitor.caches = output.1
                monitor.report("\(cache.cache.title) was kept: \(error.localizedDescription)")
            }
        }
    }

    func emptyTrash() {
        let runner = NativeSoftwareCommandRunner()
        let homePath = home.path
        perform(.trash) {
            let before = ArtifactInspector.availableBytes(at: homePath)
            let result = Result { try TrashBin.empty(runner: runner) }
            return (result, before, ArtifactInspector.availableBytes(at: homePath))
        } finish: { monitor, output in
            let (result, before, after) = output
            switch result {
            case .success(let remaining):
                monitor.trashItemCount = remaining
                // An unreadable volume capacity is unavailable, not a measured zero.
                let freed: Int64? = before.flatMap { before in after.map { max(0, $0 - before) } }
                let change = freed.map { "Free space changed by \(formatBytes(UInt64($0)))." } ?? "The free-space change could not be measured."
                monitor.message = remaining == 0
                    ? "The Trash is empty. \(change)"
                    : "Finder is still emptying the Trash; \(remaining) item(s) remain. \(change)"
                monitor.record(MaintenanceRunSummary(date: Date(), task: Step.trash.title, mode: "apply", trashedCount: 0,
                                                     trashedBytes: UInt64(freed ?? 0), protectedCount: 0, errorCount: remaining == 0 ? 0 : 1,
                                                     note: freed == nil ? MaintenanceRunSummary.spaceUnavailableNote : MaintenanceRunSummary.spaceFreedNote))
            case .failure(let error):
                monitor.report(error.localizedDescription)
            }
        }
    }

    // MARK: Plumbing

    private func perform<Output>(_ step: Step, work: @escaping () -> Output, finish: @escaping (MaintenanceMonitor, Output) -> Void) {
        guard busyStep == nil else { return }
        busyStep = step
        errorMessage = nil
        message = nil
        queue.async { [weak self] in
            let output = work()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busyStep = nil
                finish(self, output)
            }
        }
    }

    private func rootsChanged(_ step: Step) {
        message = "\(step.title): maintenance roots changed during the scan. Scan again."
    }

    private func describe(_ scan: TrashScan, step: Step) {
        scan.errors.forEach { report($0) }
        message = scan.candidates.isEmpty
            ? "\(step.title): nothing is eligible; \(scan.kept.count) item(s) kept."
            : "\(step.title): \(scan.candidates.count) item(s), \(formatBytes(scan.totalBytes)), can move to the Trash."
    }

    private func record(_ summary: MaintenanceRunSummary) {
        history = historyStore.append(summary)
    }

    private func report(_ text: String) {
        errorMessage = errorMessage.map { "\($0)\n\(text)" } ?? text
        // Messages contain paths, so they keep the unified log's default private redaction.
        logger.error("\(text)")
    }

    static func summary(_ result: MaintenanceApplyResult) -> String {
        var parts = ["Moved \(result.trashed.count) artifact(s), \(formatBytes(result.trashedBytes)) allocated, to the Trash"]
        if !result.ejected.isEmpty { parts.append("ejected \(result.ejected.count) image(s)") }
        if !result.kept.isEmpty { parts.append("kept \(result.kept.count) that changed or became active") }
        if let change = result.freeSpaceChange {
            parts.append("free space changed by \(change >= 0 ? "+" : "-")\(formatBytes(UInt64(abs(change)))) until the Trash is emptied")
        }
        return parts.joined(separator: "; ") + "."
    }

    private func reschedule() {
        timer?.cancel()
        timer = nil
        guard settings.scheduleEnabled else { return }
        let interval = settings.scheduleIntervalHours * 3_600
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval), leeway: .seconds(300))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.settings.scheduleEnabled, !self.isBusy else { return }
                self.runMergedCleanup(plan: nil, mode: "scheduled")
            }
        }
        timer.resume()
        self.timer = timer
    }
}

/// A revocable authorization shared with background work; revoking it invalidates every token
/// issued before.
private final class RunAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func revoke() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func isValid(_ token: Int) -> Bool { current() == token }
}

#if KILLSWITCH_PERFORMANCE_PROBE
extension MaintenanceMonitor {
    /// Publishes fictional plans in memory only; nothing is inspected, moved, or logged.
    func publishPerformanceFixture() {
        let now = Date()
        let identity = FileIdentity(device: 1, inode: 1, modified: 0, changed: 0, owner: getuid(), isDirectory: true, isSymbolicLink: false)
        let owner = ArtifactOwner.worktree(path: "/synthetic/copilot-worktrees/demo/session-a", head: "abc", branch: "feature-a")
        func artifact(_ path: String, _ kind: MergedArtifactKind, _ size: UInt64) -> MergedArtifact {
            MergedArtifact(path: path, kind: kind, sizeBytes: size, repository: "synthetic-owner/demo", pullRequest: 41,
                           pullRequestURL: "https://github.com/synthetic-owner/demo/pull/41", owner: owner, identity: identity, ejectDevice: nil)
        }
        var plan = MergedArtifactPlan(createdAt: now)
        plan.roots = ["/synthetic/.copilot/session-state", "/synthetic/copilot-worktrees"]
        plan.artifacts = [
            artifact("/synthetic/copilot-worktrees/demo/session-a/node_modules", .dependencies, 812_000_000),
            artifact("/synthetic/copilot-worktrees/demo/session-a/dist/Demo.dmg", .installer, 96_000_000),
            artifact("/synthetic/copilot-worktrees/demo/session-a/target", .buildOutput, 1_400_000_000)
        ]
        plan.protected = [
            MaintenanceFinding(path: "/synthetic/copilot-worktrees/demo/session-b", reason: "its agent process is running (PID 65134)"),
            MaintenanceFinding(path: "/synthetic/copilot-worktrees/demo/session-c/coverage", reason: "it contains local configuration (.env)")
        ]
        plan.skipped = [MaintenanceFinding(path: "/synthetic/copilot-worktrees/demo/session-d", reason: "PR #42 was closed without merging")]
        plan.worktreeCandidates = [WorktreeCandidate(path: "/synthetic/copilot-worktrees/demo/session-a", mainCheckout: "/synthetic/src/demo",
                                                      repository: "synthetic-owner/demo", pullRequest: 41, head: "abc", branch: "feature-a")]
        plan.sessionCandidates = [SessionCandidate(directory: "/synthetic/.copilot/session-state/archived", repository: "synthetic-owner/demo", pullRequest: 40)]
        mergedPlan = plan
        history = [
            MaintenanceRunSummary(date: now.addingTimeInterval(-3_600), task: Step.mergedArtifacts.title, mode: "scheduled",
                                  trashedCount: 4, trashedBytes: 2_300_000_000, protectedCount: 3, errorCount: 0),
            MaintenanceRunSummary(date: now.addingTimeInterval(-7_200), task: Step.trash.title, mode: "apply",
                                  trashedCount: 0, trashedBytes: 2_100_000_000, protectedCount: 0, errorCount: 0,
                                  note: MaintenanceRunSummary.spaceFreedNote)
        ]
    }
}
#endif
