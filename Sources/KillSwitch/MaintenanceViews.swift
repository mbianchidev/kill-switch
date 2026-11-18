import AppKit
import MaintenanceCore
import SwiftUI
import TableQueryCore

private func bytesValue(_ bytes: UInt64) -> Decimal? { Decimal(bytes) }

private enum ArtifactFields {
    static let path = TableField<MergedArtifact>.text("path", title: "Path") { $0.path }
    static let kind = TableField<MergedArtifact>.text("kind", title: "Kind", aliases: ["type"], searchable: false) { $0.kind.title }
    static let repository = TableField<MergedArtifact>.text("repository", title: "Repository", aliases: ["repo"]) { $0.repository }
    static let pullRequest = TableField<MergedArtifact>.number("pr", title: "Pull request", aliases: ["pullRequest"], searchable: true) {
        (artifact: MergedArtifact) -> Decimal? in Decimal(artifact.pullRequest)
    }
    static let size = TableField<MergedArtifact>.number("size", title: "Size", unit: .bytes) { bytesValue($0.sizeBytes) }
    static let all = [path, kind, repository, pullRequest, size]
}

private enum WorktreeFields {
    static let path = TableField<WorktreeCandidate>.text("path", title: "Worktree", aliases: ["worktree"]) { $0.path }
    static let branch = TableField<WorktreeCandidate>.text("branch", title: "Branch") { $0.branch }
    static let repository = TableField<WorktreeCandidate>.text("repository", title: "Repository", aliases: ["repo"]) { $0.repository }
    static let pullRequest = TableField<WorktreeCandidate>.number("pr", title: "Pull request", aliases: ["pullRequest"], searchable: true) {
        (candidate: WorktreeCandidate) -> Decimal? in Decimal(candidate.pullRequest)
    }
    static let all = [path, branch, repository, pullRequest]
}

private enum SessionFields {
    static let path = TableField<SessionCandidate>.text("path", title: "Session", aliases: ["session", "directory"]) { $0.directory }
    static let repository = TableField<SessionCandidate>.text("repository", title: "Repository", aliases: ["repo"]) { $0.repository }
    static let pullRequest = TableField<SessionCandidate>.number("pr", title: "Pull request", aliases: ["pullRequest"], searchable: true) {
        (candidate: SessionCandidate) -> Decimal? in Decimal(candidate.pullRequest)
    }
    static let all = [path, repository, pullRequest]
}

private enum TrashCandidateFields {
    static let path = TableField<TrashCandidate>.text("path", title: "Path") { $0.path }
    static let detail = TableField<TrashCandidate>.text("detail", title: "Detail", aliases: ["reason"]) { $0.detail }
    static let size = TableField<TrashCandidate>.number("size", title: "Size", unit: .bytes) { bytesValue($0.sizeBytes) }
    static let all = [path, detail, size]
}

private enum CacheFields {
    static let name = TableField<ToolCacheStatus>.text("cache", title: "Cache", aliases: ["name", "tool"]) { $0.cache.title }
    static let path = TableField<ToolCacheStatus>.text("path", title: "Path") { $0.cache.paths.first }
    static let size = TableField<ToolCacheStatus>.number("size", title: "Size", unit: .bytes) { bytesValue($0.sizeBytes) }
    static let state = TableField<ToolCacheStatus>.text("state", title: "State", aliases: ["status"], values: ["Ready", "Kept"], searchable: false) {
        $0.blocker == nil ? "Ready" : "Kept"
    }
    static let all = [name, size, state, path]
}

private enum HistoryFields {
    static let date = TableField<MaintenanceRunSummary>.date("date", title: "Time", aliases: ["time"]) { $0.date }
    static let task = TableField<MaintenanceRunSummary>.text("task", title: "Task") { $0.task }
    static let mode = TableField<MaintenanceRunSummary>.text("mode", title: "Mode", values: ["Automatic", "Manual"], searchable: false) {
        $0.mode == "scheduled" ? "Automatic" : "Manual"
    }
    static let items = TableField<MaintenanceRunSummary>.number("items", title: "Items", aliases: ["count"]) {
        (entry: MaintenanceRunSummary) -> Decimal? in Decimal(entry.trashedCount)
    }
    /// Unmeasured free-space changes are unavailable, not zero, so they never match or sort as 0 bytes.
    static let size = TableField<MaintenanceRunSummary>.number("size", title: "Size", unit: .bytes) {
        (entry: MaintenanceRunSummary) -> Decimal? in
        entry.note == MaintenanceRunSummary.spaceUnavailableNote ? nil : bytesValue(entry.trashedBytes)
    }
    static let errors = TableField<MaintenanceRunSummary>.number("errors", title: "Errors") {
        (entry: MaintenanceRunSummary) -> Decimal? in Decimal(entry.errorCount)
    }
    static let all = [date, task, mode, items, size, errors]
}

private enum FindingFields {
    static let path = TableField<MaintenanceFinding>.text("path", title: "Path") { $0.path }
    static let reason = TableField<MaintenanceFinding>.text("reason", title: "Reason") { $0.reason }
    static let all = [path, reason]
}

private enum MaintenanceConfirmation: Identifiable {
    case applyMerged(count: Int, bytes: UInt64)
    case trashStep(MaintenanceMonitor.Step, count: Int, bytes: UInt64)
    case removeWorktree(WorktreeCandidate)
    case clearCache(ToolCacheStatus)
    case emptyTrash(Int?)
    case enableTrashSchedule(days: Int)

    var id: String {
        switch self {
        case .applyMerged: return "merged"
        case .trashStep(let step, _, _): return "step-\(step.rawValue)"
        case .removeWorktree(let candidate): return "worktree-\(candidate.path)"
        case .clearCache(let cache): return "cache-\(cache.id)"
        case .emptyTrash: return "trash"
        case .enableTrashSchedule: return "trash-schedule"
        }
    }
}

struct MaintenanceView: View {
    @ObservedObject var monitor: MaintenanceMonitor
    let tableStates: TableStateStore
    @Environment(\.allowsLiveOperations) private var allowsOperations
    @State private var confirmation: MaintenanceConfirmation?
    @State private var showsSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = monitor.errorMessage {
                    NoticeBanner(message: error, dismiss: monitor.clearMessages)
                } else if let message = monitor.message {
                    NoticeBanner(message: message, systemImage: "checkmark.circle.fill", color: .green, dismiss: monitor.clearMessages)
                }
                if let warning = monitor.settingsWarning { NoticeBanner(message: warning) }
                mergedCard
                stepCard(.archives, scan: monitor.archiveScan,
                         summary: "Untracked archives in agent worktrees, idle for \(monitor.settings.archiveIdleHours) hours and not open.",
                         detail: "Covers .zip, .tar.gz, .7z, and similar archives. Tracked archives and session history are never touched.")
                stepCard(.diskImages, scan: monitor.diskImageScan,
                         summary: "Disk images in Downloads and Desktop whose apps are already installed.",
                         detail: "Each image is attached read-only and detached again to compare app versions. Nothing else in Downloads is opened.")
                stepCard(.buildOutput, scan: monitor.buildScan,
                         summary: "Ignored target, node_modules, and build folders in clean repositories unused for \(monitor.settings.buildIdleDays) days.",
                         detail: "Found in checkouts under the repository roots. Restore them with the project's install or build command.")
                cachesCard
                trashCard
                historyCard
                settingsCard
            }
            .padding(16)
        }
        .alert(item: $confirmation) { item in
            alert(for: item)
        }
    }

    // MARK: Merged artifacts

    private var mergedCard: some View {
        card(
            MaintenanceMonitor.Step.mergedArtifacts, icon: "checkmark.seal",
            summary: "Installers, dependencies, and build output from merged PRs in agent sessions and worktrees. Whole sessions and worktrees are only listed for your approval.",
            detail: "Each worktree must be inactive, clean, and at the merged PR's head. GitHub is checked read-only with your gh account, and every item is checked again right before it moves to the Trash."
        ) {
            Button("Preview") { monitor.previewMergedArtifacts() }
                .disabled(monitor.isBusy || !allowsOperations)
                .help("Build the exact list without changing anything")
            Button("Move \(monitor.mergedPlan?.artifacts.count ?? 0) to Trash") {
                if let plan = monitor.mergedPlan { confirmation = .applyMerged(count: plan.artifacts.count, bytes: plan.totalBytes) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(monitor.isBusy || (monitor.mergedPlan?.artifacts.isEmpty ?? true) || !allowsOperations)
        } content: {
            HStack(spacing: 8) {
                Toggle("Run automatically", isOn: Binding(
                    get: { monitor.settings.scheduleEnabled },
                    set: { monitor.setSchedule(enabled: $0, intervalHours: monitor.settings.scheduleIntervalHours) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Off by default. When on, eligible merged-PR artifacts move to the Trash without asking; sessions and worktrees are never removed.")
                Picker("Every", selection: Binding(
                    get: { monitor.settings.scheduleIntervalHours },
                    set: { monitor.setSchedule(enabled: monitor.settings.scheduleEnabled, intervalHours: $0) }
                )) {
                    ForEach(MaintenanceSettings.scheduleOptions, id: \.self) { Text("\($0)h").tag($0) }
                }
                .labelsHidden()
                .frame(width: 70)
                .controlSize(.small)
                .disabled(!monitor.settings.scheduleEnabled)
                Spacer()
                if let last = monitor.lastScheduledRun {
                    Text("Last automatic run: \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            if let result = monitor.mergedResult { resultSummary(result) }
            if let plan = monitor.mergedPlan { planDetails(plan) }
            HStack(spacing: 6) {
                Text("Audit log: \(MaintenancePath.abbreviate(monitor.auditLogURL.path, home: monitor.home)) (5 MB, two older copies)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .copyOnClick(monitor.auditLogURL.path, label: "audit log path")
                Button { _ = revealPathInFinder(monitor.auditLogURL.path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .disabled(!FileManager.default.fileExists(atPath: monitor.auditLogURL.path))
                    .help("Reveal the audit log in Finder")
                    .accessibilityLabel("Reveal the audit log in Finder")
            }
        }
    }

    private func resultSummary(_ result: MaintenanceApplyResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(MaintenanceMonitor.summary(result), systemImage: result.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(result.errors.isEmpty ? .green : .orange)
            ForEach(result.errors, id: \.self) { Text($0).font(.system(size: 11)).foregroundColor(.orange).textSelection(.enabled) }
            findings("Kept at removal time", result.kept, key: "merged-kept")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    @ViewBuilder
    private func planDetails(_ plan: MergedArtifactPlan) -> some View {
        if !plan.isComplete {
            NoticeBanner(message: "The preview is incomplete, so some candidates were not checked: \(plan.errors.joined(separator: " "))")
        }
        Text("Preview \(plan.createdAt.formatted(date: .omitted, time: .shortened)): \(plan.artifacts.count) eligible (\(formatBytes(plan.totalBytes)) allocated), \(plan.protected.count) protected, \(plan.skipped.count) skipped")
            .font(.system(size: 12, weight: .semibold))
        if !plan.artifacts.isEmpty {
            EmbeddedDataTable(
                plan.artifacts, fields: ArtifactFields.all, sortedBy: TableComparator(field: ArtifactFields.size, order: .reverse),
                state: tableStates, key: "artifacts",
                identity: \.id, prompt: "Search paths or repositories, or size > 100MB"
            ) {
                TableColumn("Kind", sortUsing: TableComparator(field: ArtifactFields.kind)) { artifact in
                    StatusBadge(title: artifact.kind.title, color: Theme.diskCleanupAccent)
                }
                .width(min: 70, ideal: 110)
                TableColumn("Path", sortUsing: TableComparator(field: ArtifactFields.path)) { artifact in
                    pathText(artifact.path)
                }
                .width(min: 160, ideal: 340)
                TableColumn("Pull request", sortUsing: TableComparator(field: ArtifactFields.pullRequest)) { artifact in
                    pullRequestLink(artifact.repository, artifact.pullRequest, artifact.pullRequestURL)
                }
                .width(min: 100, ideal: 170)
                TableColumn("Size", sortUsing: TableComparator(field: ArtifactFields.size)) { artifact in
                    Text(formatBytes(artifact.sizeBytes)).font(.system(size: 11, design: .monospaced))
                }
                .width(min: 60, ideal: 80)
            }
        }
        if !plan.worktreeCandidates.isEmpty || !plan.sessionCandidates.isEmpty {
            Text("Need your approval").font(.system(size: 12, weight: .semibold)).padding(.top, 4)
            if !plan.worktreeCandidates.isEmpty {
                EmbeddedDataTable(
                    plan.worktreeCandidates, fields: WorktreeFields.all, sortedBy: TableComparator(field: WorktreeFields.path),
                    state: tableStates, key: "worktrees",
                    identity: \.id, prompt: "Search worktrees, branches, or repositories"
                ) {
                    TableColumn("Worktree", sortUsing: TableComparator(field: WorktreeFields.path)) { candidate in
                        Label { pathText(candidate.path) } icon: {
                            Image(systemName: "folder.badge.minus").foregroundColor(.orange)
                        }
                    }
                    .width(min: 160, ideal: 300)
                    TableColumn("Branch", sortUsing: TableComparator(field: WorktreeFields.branch)) { candidate in
                        Text(candidate.branch).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                            .copyOnClick(candidate.branch, label: "branch")
                    }
                    .width(min: 80, ideal: 150)
                    TableColumn("Pull request", sortUsing: TableComparator(field: WorktreeFields.pullRequest)) { candidate in
                        pullRequestLink(candidate.repository, candidate.pullRequest, nil)
                    }
                    .width(min: 100, ideal: 170)
                    TableColumn("Actions") { candidate in
                        HStack(spacing: 6) {
                            revealButton(candidate.path)
                            Button("Remove…") { confirmation = .removeWorktree(candidate) }
                                .controlSize(.small)
                                .disabled(monitor.isBusy || !allowsOperations)
                                .help("Runs git worktree remove without --force after rechecking it")
                        }
                    }
                    .width(min: 110, ideal: 110)
                }
            }
            if !plan.sessionCandidates.isEmpty {
                EmbeddedDataTable(
                    plan.sessionCandidates, fields: SessionFields.all, sortedBy: TableComparator(field: SessionFields.path),
                    state: tableStates, key: "sessions",
                    identity: \.id, prompt: "Search sessions or repositories"
                ) {
                    TableColumn("Session", sortUsing: TableComparator(field: SessionFields.path)) { candidate in
                        Label { pathText(candidate.directory) } icon: {
                            Image(systemName: "bubble.left.and.text.bubble.right").foregroundColor(.secondary)
                        }
                        .help("Its worktree is gone and its PR merged. KillSwitch never deletes session history; archive or remove it in its app if you no longer need it.")
                    }
                    .width(min: 160, ideal: 320)
                    TableColumn("Pull request", sortUsing: TableComparator(field: SessionFields.pullRequest)) { candidate in
                        pullRequestLink(candidate.repository, candidate.pullRequest, nil)
                    }
                    .width(min: 100, ideal: 170)
                    TableColumn("Reveal") { candidate in revealButton(candidate.directory) }
                        .width(min: 50, ideal: 50)
                }
            }
        }
        findings("Protected", plan.protected, key: "merged-protected")
        findings("Skipped", plan.skipped, key: "merged-skipped")
    }

    private func pullRequestLink(_ repository: String, _ number: Int, _ url: String?) -> some View {
        let target = url.flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(repository)/pull/\(number)")
        return Group {
            if let target {
                Link("\(repository)#\(number)", destination: target)
            } else {
                Text("\(repository)#\(number)")
            }
        }
        .font(.system(size: 11))
    }

    // MARK: Skill steps

    private func stepCard(_ step: MaintenanceMonitor.Step, scan: TrashScan?, summary: String, detail: String) -> some View {
        card(step, icon: icon(step), summary: summary, detail: detail) {
            Button("Scan") { monitor.scan(step) }
                .disabled(monitor.isBusy || !allowsOperations)
            Button("Move \(scan?.candidates.count ?? 0) to Trash") {
                if let scan { confirmation = .trashStep(step, count: scan.candidates.count, bytes: scan.totalBytes) }
            }
            .disabled(monitor.isBusy || (scan?.candidates.isEmpty ?? true) || !allowsOperations)
        } content: {
            if let scan {
                Text("\(scan.candidates.count) eligible · \(formatBytes(scan.totalBytes)) · \(scan.kept.count) kept")
                    .font(.system(size: 11, weight: .medium))
                ForEach(scan.errors, id: \.self) { NoticeBanner(message: $0) }
                if !scan.candidates.isEmpty {
                    EmbeddedDataTable(
                        scan.candidates, fields: TrashCandidateFields.all,
                        sortedBy: TableComparator(field: TrashCandidateFields.size, order: .reverse),
                        state: tableStates, key: "\(step.rawValue)-candidates",
                        identity: \.id, prompt: "Search paths, or size > 1GB"
                    ) {
                        TableColumn("Path", sortUsing: TableComparator(field: TrashCandidateFields.path)) { candidate in
                            pathText(candidate.path)
                        }
                        .width(min: 160, ideal: 340)
                        TableColumn("Detail", sortUsing: TableComparator(field: TrashCandidateFields.detail)) { candidate in
                            Text(candidate.detail).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).help(candidate.detail)
                        }
                        .width(min: 100, ideal: 200)
                        TableColumn("Size", sortUsing: TableComparator(field: TrashCandidateFields.size)) { candidate in
                            Text(formatBytes(candidate.sizeBytes)).font(.system(size: 11, design: .monospaced))
                        }
                        .width(min: 60, ideal: 80)
                        TableColumn("Reveal") { candidate in revealButton(candidate.path) }
                            .width(min: 50, ideal: 50)
                    }
                }
                findings("Kept", scan.kept, key: "\(step.rawValue)-kept")
            }
            if let last = monitor.lastTrashResult, last.step == step {
                findings("Kept at removal time", last.result.kept, key: "\(step.rawValue)-removal-kept")
            }
        }
    }

    private var cachesCard: some View {
        card(
            .caches, icon: "shippingbox",
            summary: "Clears tool caches with each tool's own command; they refill on demand.",
            detail: "A cache is kept while a program that uses it runs. Modules and crates download again on the next build."
        ) {
            Button("Check caches") { monitor.scan(.caches) }
                .disabled(monitor.isBusy || !allowsOperations)
        } content: {
            if let caches = monitor.caches {
                if caches.isEmpty { Text("No supported caches were found.").font(.system(size: 11)).foregroundColor(.secondary) }
                if !caches.isEmpty {
                    EmbeddedDataTable(
                        caches, fields: CacheFields.all, sortedBy: TableComparator(field: CacheFields.size, order: .reverse),
                        state: tableStates, key: "caches",
                        identity: \.id, prompt: "Search caches, or state = Ready", rowHeight: 40
                    ) {
                        TableColumn("Cache", sortUsing: TableComparator(field: CacheFields.name)) { cache in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cache.cache.title).font(.system(size: 12, weight: .medium))
                                Text(cache.blocker.map { "Kept: \($0)" } ?? cache.cache.note ?? MaintenancePath.abbreviate(cache.cache.paths[0], home: monitor.home))
                                    .font(.system(size: 10)).foregroundColor(cache.blocker == nil ? .secondary : .orange)
                                    .lineLimit(1)
                                    .help(cache.blocker ?? cache.cache.note ?? cache.cache.paths[0])
                            }
                        }
                        .width(min: 160, ideal: 360)
                        TableColumn("Size", sortUsing: TableComparator(field: CacheFields.size)) { cache in
                            Text(formatBytes(cache.sizeBytes)).font(.system(size: 11, design: .monospaced))
                        }
                        .width(min: 60, ideal: 80)
                        TableColumn("Clear") { cache in
                            Button("Clear…") { confirmation = .clearCache(cache) }
                                .controlSize(.small)
                                .disabled(cache.blocker != nil || monitor.isBusy || !allowsOperations)
                        }
                        .width(min: 70, ideal: 70)
                    }
                }
            }
        }
    }

    private var trashCard: some View {
        card(
            .trash, icon: "trash",
            summary: monitor.trashItemCount.map { "\($0) item(s) in the Trash. Everything above stays recoverable until it is emptied." }
                ?? "Everything above stays recoverable in the Trash until it is emptied.",
            detail: "Emptying asks Finder, which may need Automation permission."
        ) {
            Button("Count items") { monitor.scan(.trash) }
                .disabled(monitor.isBusy || !allowsOperations)
            Button("Empty Trash…", role: .destructive) { confirmation = .emptyTrash(monitor.trashItemCount) }
                .disabled(monitor.isBusy || monitor.trashItemCount == 0 || !allowsOperations)
        } content: {
            HStack(spacing: 8) {
                Toggle("Empty automatically", isOn: Binding(
                    get: { monitor.settings.trashScheduleEnabled },
                    set: { enabled in
                        if enabled {
                            confirmation = .enableTrashSchedule(days: monitor.settings.trashScheduleIntervalDays)
                        } else {
                            monitor.setTrashSchedule(enabled: false, intervalDays: monitor.settings.trashScheduleIntervalDays)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Off by default. When on, everything in the Trash is permanently deleted every interval while KillSwitch runs.")
                Picker("Every", selection: Binding(
                    get: { monitor.settings.trashScheduleIntervalDays },
                    set: { monitor.setTrashSchedule(enabled: monitor.settings.trashScheduleEnabled, intervalDays: $0) }
                )) {
                    ForEach(MaintenanceSettings.trashScheduleOptions, id: \.self) { Text(Self.trashIntervalTitle($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                Spacer()
                if let next = monitor.settings.nextTrashEmpty {
                    Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            if monitor.settings.trashScheduleEnabled {
                Text("Automatic emptying permanently deletes everything in the Trash, including items you moved there yourself. A missed run happens shortly after KillSwitch starts.")
                    .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func trashIntervalTitle(_ days: Int) -> String {
        switch days {
        case 1: return "Daily"
        case 7: return "Weekly"
        default: return "Every \(days) days"
        }
    }

    private var historyCard: some View {
        let entries = monitor.history
        let spaceNotes: Set<String?> = [MaintenanceRunSummary.spaceFreedNote, MaintenanceRunSummary.spaceUnavailableNote]
        let moved = entries.reduce(UInt64(0)) { $0 + (spaceNotes.contains($1.note) ? 0 : $1.trashedBytes) }
        let freed = entries.filter { $0.note == MaintenanceRunSummary.spaceFreedNote }.reduce(UInt64(0)) { $0 + $1.trashedBytes }
        return VStack(alignment: .leading, spacing: 8) {
            Label("Last 24 hours", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.accent)
            if entries.isEmpty {
                Text("No maintenance ran in the last 24 hours.").font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                Text("\(entries.count) run(s): \(formatBytes(moved)) moved to the Trash, \(formatBytes(freed)) freed by emptying it, \(entries.reduce(0) { $0 + $1.errorCount }) error(s).")
                    .font(.system(size: 12, weight: .medium))
                EmbeddedDataTable(
                    entries, fields: HistoryFields.all, sortedBy: TableComparator(field: HistoryFields.date, order: .reverse),
                    state: tableStates, key: "history",
                    identity: { String($0.date.timeIntervalSinceReferenceDate) }, prompt: "Search tasks, or errors > 0"
                ) {
                    TableColumn("Time", sortUsing: TableComparator(field: HistoryFields.date)) { entry in
                        Text(entry.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    }
                    .width(min: 50, ideal: 70)
                    TableColumn("Task", sortUsing: TableComparator(field: HistoryFields.task)) { entry in
                        Text(entry.task).font(.system(size: 11))
                    }
                    .width(min: 100, ideal: 200)
                    TableColumn("Mode", sortUsing: TableComparator(field: HistoryFields.mode)) { entry in
                        if entry.mode == "scheduled" { StatusBadge(title: "Automatic", color: Theme.accent) } else { Text("Manual") }
                    }
                    .width(min: 60, ideal: 90)
                    TableColumn("Result", sortUsing: TableComparator(field: HistoryFields.size)) { entry in
                        Text(entry.note == MaintenanceRunSummary.spaceFreedNote ? "\(formatBytes(entry.trashedBytes)) freed"
                             : entry.note == MaintenanceRunSummary.spaceUnavailableNote ? "space change unavailable"
                             : "\(entry.trashedCount) item(s), \(formatBytes(entry.trashedBytes))")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .width(min: 100, ideal: 170)
                    TableColumn("Errors", sortUsing: TableComparator(field: HistoryFields.errors)) { entry in
                        if entry.errorCount > 0 { StatusBadge(title: "\(entry.errorCount) error(s)", color: .orange) } else { Text("None") }
                    }
                    .width(min: 50, ideal: 80)
                }
            }
            Text("Only counts and sizes are kept, for 24 hours. Paths and reasons for merged-PR runs are in the audit log.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    private var settingsCard: some View {
        DisclosureGroup(isExpanded: $showsSettings) {
            settingsContent.padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Label("Settings", systemImage: "folder.badge.gearshape")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.accent)
                Text(settingsSummary).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    private var settingsSummary: String {
        let settings = monitor.settings
        return "\(settings.artifactRoots.count) agent root(s) · \(settings.repositoryRoots.count) repository root(s) · "
            + "archives \(settings.archiveIdleHours)h · build output \(settings.buildIdleDays)d"
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Maintenance roots").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Reset to defaults") { monitor.resetRoots() }.controlSize(.small).disabled(monitor.isBusy)
            }
            rootList("Agent sessions and worktrees", detail: "Merged PR artifacts and archives are found here. Defaults: ~/.copilot/session-state and ~/workspace/copilot-worktrees.",
                     roots: monitor.settings.artifactRoots, repository: false)
            rootList("Repository roots", detail: "Idle build output is found in checkouts directly inside these folders and their worktrees.",
                     roots: monitor.settings.repositoryRoots, repository: true)
            HStack(spacing: 16) {
                Picker("Archives idle for", selection: Binding(get: { monitor.settings.archiveIdleHours }, set: { monitor.setIdle(archiveHours: $0) })) {
                    ForEach([6, 12, 24, 48, 72], id: \.self) { Text("\($0) hours").tag($0) }
                }
                .frame(width: 220)
                Picker("Build output idle for", selection: Binding(get: { monitor.settings.buildIdleDays }, set: { monitor.setIdle(buildDays: $0) })) {
                    ForEach([3, 7, 14, 30, 60], id: \.self) { Text("\($0) days").tag($0) }
                }
                .frame(width: 240)
            }
            .controlSize(.small)
            Text("Roots must be folders in your home folder. ~/Downloads, ~/Library, and the Trash are refused. Session history, Git metadata, VM disks, models, and app data are never removed.")
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rootList(_ title: String, detail: String, roots: [String], repository: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    chooseRoots(repository: repository)
                } label: { Label("Add…", systemImage: "plus") }
                    .controlSize(.small)
                    .disabled(monitor.isBusy)
            }
            Text(detail).font(.system(size: 10)).foregroundColor(.secondary)
            if roots.isEmpty { Text("No roots.").font(.system(size: 11)).foregroundColor(.secondary) }
            ForEach(roots, id: \.self) { root in
                HStack {
                    Text(MaintenancePath.abbreviate(root, home: monitor.home)).font(.system(size: 11, design: .monospaced))
                    if !FileManager.default.fileExists(atPath: root) { StatusBadge(title: "Missing", color: .orange) }
                    Spacer()
                    Button { monitor.removeRoot(root, repository: repository) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(monitor.isBusy)
                        .help("Stop using this root")
                        .accessibilityLabel("Remove root \(root)")
                }
            }
        }
    }

    // MARK: Helpers

    /// A card with its actions in the header, a one-line summary, and longer detail on hover.
    private func card<Actions: View, Content: View>(
        _ step: MaintenanceMonitor.Step, icon: String, summary: String, detail: String,
        @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(step.title, systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.accent)
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .help(detail)
                    .accessibilityLabel(detail)
                busyIndicator(step)
                Spacer(minLength: 8)
                HStack(spacing: 6) { actions() }.controlSize(.small)
            }
            Text(summary).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    @ViewBuilder
    private func busyIndicator(_ step: MaintenanceMonitor.Step) -> some View {
        if monitor.busyStep == step {
            ProgressView().controlSize(.small)
            Text("Working…").font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func findings(_ title: String, _ items: [MaintenanceFinding], key: String) -> some View {
        if !items.isEmpty {
            DisclosureGroup("\(title) (\(items.count))") {
                EmbeddedDataTable(
                    items, fields: FindingFields.all, sortedBy: TableComparator(field: FindingFields.path),
                    state: tableStates, key: "findings-\(key)",
                    identity: \.id, prompt: "Search paths or reasons"
                ) {
                    TableColumn("Path", sortUsing: TableComparator(field: FindingFields.path)) { finding in
                        pathText(finding.path)
                    }
                    .width(min: 160, ideal: 360)
                    TableColumn("Reason", sortUsing: TableComparator(field: FindingFields.reason)) { finding in
                        Text(finding.reason).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).help(finding.reason)
                    }
                    .width(min: 120, ideal: 300)
                }
            }
            .font(.system(size: 11))
        }
    }

    /// An abbreviated path that shows the full path on hover and copies it on click.
    private func pathText(_ path: String) -> some View {
        Text(MaintenancePath.abbreviate(path, home: monitor.home))
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .copyOnClick(path, label: "path")
    }

    private func revealButton(_ path: String) -> some View {
        Button { _ = revealPathInFinder(path) } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \((path as NSString).lastPathComponent) in Finder")
    }

    private func icon(_ step: MaintenanceMonitor.Step) -> String {
        switch step {
        case .archives: return "doc.zipper"
        case .diskImages: return "externaldrive.badge.checkmark"
        case .buildOutput: return "hammer"
        default: return "wrench.and.screwdriver"
        }
    }

    private func chooseRoots(repository: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = repository ? "Choose folders that contain your repositories." : "Choose folders that hold agent sessions or worktrees."
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { monitor.addRoot($0, repository: repository) }
    }

    private func alert(for item: MaintenanceConfirmation) -> Alert {
        switch item {
        case let .applyMerged(count, bytes):
            return Alert(
                title: Text("Move \(count) merged-PR artifact(s) to the Trash?"),
                message: Text("\(formatBytes(bytes)) allocated. Each item, its worktree or session, and its use are rechecked first; anything that changed is kept. Sessions and worktrees themselves stay."),
                primaryButton: .destructive(Text("Move to Trash")) { monitor.applyMergedArtifacts() },
                secondaryButton: .cancel()
            )
        case let .trashStep(step, count, bytes):
            return Alert(
                title: Text("Move \(count) item(s) to the Trash?"),
                message: Text("\(step.title): \(formatBytes(bytes)). Each item is rechecked first. Nothing is permanently deleted until you empty the Trash."),
                primaryButton: .destructive(Text("Move to Trash")) { monitor.moveToTrash(step) },
                secondaryButton: .cancel()
            )
        case .removeWorktree(let candidate):
            return Alert(
                title: Text("Remove this worktree?"),
                message: Text("\(candidate.path)\n\nRuns git worktree remove without --force for merged \(candidate.repository)#\(candidate.pullRequest). Git refuses if anything changed. Its branch and session history are kept."),
                primaryButton: .destructive(Text("Remove worktree")) { monitor.removeWorktree(candidate) },
                secondaryButton: .cancel()
            )
        case .clearCache(let cache):
            return Alert(
                title: Text("Clear \(cache.cache.title)?"),
                message: Text("\(formatBytes(cache.sizeBytes)). \(cache.cache.note ?? "It refills on demand.")"),
                primaryButton: .destructive(Text("Clear")) { monitor.clearCache(cache) },
                secondaryButton: .cancel()
            )
        case .emptyTrash(let count):
            return Alert(
                title: Text("Empty the Trash?"),
                message: Text("\(count.map { "\($0) item(s) will be permanently deleted" } ?? "Everything in the Trash will be permanently deleted"), including items you moved there yourself. This cannot be undone."),
                primaryButton: .destructive(Text("Empty Trash")) { monitor.emptyTrash() },
                secondaryButton: .cancel()
            )
        case .enableTrashSchedule(let days):
            return Alert(
                title: Text("Empty the Trash automatically?"),
                message: Text("\(Self.trashIntervalTitle(days)), KillSwitch will permanently delete everything in the Trash, including items you moved there yourself, without asking. The first automatic empty is \(days == 1 ? "in a day" : "in \(days) days"). Finder may ask now for permission to let KillSwitch control it."),
                primaryButton: .destructive(Text("Turn On")) {
                    monitor.setTrashSchedule(enabled: true, intervalDays: days)
                    // Counting asks for Finder Automation permission now, while you are here.
                    if allowsOperations { monitor.scan(.trash) }
                },
                secondaryButton: .cancel()
            )
        }
    }
}
