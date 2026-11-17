import AppKit
import MaintenanceCore
import SwiftUI

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
    @Environment(\.allowsLiveOperations) private var allowsOperations
    @State private var confirmation: MaintenanceConfirmation?

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
                         description: "Untracked .zip, .tar.gz, .7z, and similar archives left in agent worktrees, idle for \(monitor.settings.archiveIdleHours) hour(s) and not open. Tracked archives and session history are never touched.")
                stepCard(.diskImages, scan: monitor.diskImageScan,
                         description: "DMGs in ~/Downloads and ~/Desktop whose apps are already installed at the same or a newer version. Each image is attached read-only and detached again; nothing else in Downloads is opened.")
                stepCard(.buildOutput, scan: monitor.buildScan,
                         description: "Ignored target, node_modules, and build folders in clean checkouts under the repository roots that nobody has used for \(monitor.settings.buildIdleDays) day(s). Restore them with the project's install or build command.")
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
        card(MaintenanceMonitor.Step.mergedArtifacts, icon: "checkmark.seal") {
            Text("Moves generated installers, staged apps, dependencies, and build and test output belonging to merged pull requests from agent sessions and worktrees to the Trash. Each worktree must be inactive, clean, and at the merged PR's head; GitHub is checked read-only with your gh account. Whole sessions and worktrees are only listed for your approval.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Preview") { monitor.previewMergedArtifacts() }
                    .disabled(monitor.isBusy || !allowsOperations)
                    .help("Build the exact list without changing anything")
                Button("Move \(monitor.mergedPlan?.artifacts.count ?? 0) to Trash") {
                    if let plan = monitor.mergedPlan { confirmation = .applyMerged(count: plan.artifacts.count, bytes: plan.totalBytes) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(monitor.isBusy || (monitor.mergedPlan?.artifacts.isEmpty ?? true) || !allowsOperations)
                busyIndicator(.mergedArtifacts)
                Spacer()
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
                .disabled(!monitor.settings.scheduleEnabled)
            }
            if let last = monitor.lastScheduledRun {
                Text("Last automatic run: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundColor(.secondary)
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
            findings("Kept at removal time", result.kept)
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
        ForEach(plan.artifacts) { artifact in
            HStack(spacing: 10) {
                StatusBadge(title: artifact.kind.title, color: Theme.diskCleanupAccent)
                    .frame(width: 110, alignment: .leading)
                Text(MaintenancePath.abbreviate(artifact.path, home: monitor.home))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(artifact.path)
                Spacer()
                pullRequestLink(artifact.repository, artifact.pullRequest, artifact.pullRequestURL)
                Text(formatBytes(artifact.sizeBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 80, alignment: .trailing)
            }
        }
        if !plan.worktreeCandidates.isEmpty || !plan.sessionCandidates.isEmpty {
            Text("Need your approval").font(.system(size: 12, weight: .semibold)).padding(.top, 4)
            ForEach(plan.worktreeCandidates) { candidate in
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.minus").foregroundColor(.orange).accessibilityHidden(true)
                    Text("Worktree \(MaintenancePath.abbreviate(candidate.path, home: monitor.home))")
                        .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    pullRequestLink(candidate.repository, candidate.pullRequest, nil)
                    revealButton(candidate.path)
                    Button("Remove…") { confirmation = .removeWorktree(candidate) }
                        .controlSize(.small)
                        .disabled(monitor.isBusy || !allowsOperations)
                        .help("Runs git worktree remove without --force after rechecking it")
                }
            }
            ForEach(plan.sessionCandidates) { candidate in
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right").foregroundColor(.secondary).accessibilityHidden(true)
                    Text("Session \(MaintenancePath.abbreviate(candidate.directory, home: monitor.home))")
                        .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    pullRequestLink(candidate.repository, candidate.pullRequest, nil)
                    revealButton(candidate.directory)
                }
                .help("Its worktree is gone and its PR merged. KillSwitch never deletes session history; archive or remove it in its app if you no longer need it.")
            }
        }
        findings("Protected", plan.protected)
        findings("Skipped", plan.skipped)
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

    private func stepCard(_ step: MaintenanceMonitor.Step, scan: TrashScan?, description: String) -> some View {
        card(step, icon: icon(step)) {
            Text(description).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Scan") { monitor.scan(step) }
                    .disabled(monitor.isBusy || !allowsOperations)
                Button("Move \(scan?.candidates.count ?? 0) to Trash") {
                    if let scan { confirmation = .trashStep(step, count: scan.candidates.count, bytes: scan.totalBytes) }
                }
                .disabled(monitor.isBusy || (scan?.candidates.isEmpty ?? true) || !allowsOperations)
                busyIndicator(step)
                Spacer()
                if let scan {
                    Text("\(scan.candidates.count) eligible · \(formatBytes(scan.totalBytes)) · \(scan.kept.count) kept")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            if let scan {
                ForEach(scan.errors, id: \.self) { NoticeBanner(message: $0) }
                ForEach(scan.candidates.prefix(40)) { candidate in
                    HStack(spacing: 8) {
                        Text(MaintenancePath.abbreviate(candidate.path, home: monitor.home))
                            .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            .help(candidate.detail)
                        Spacer()
                        Text(formatBytes(candidate.sizeBytes)).font(.system(size: 11, design: .monospaced))
                        revealButton(candidate.path)
                    }
                }
                if scan.candidates.count > 40 {
                    Text("And \(scan.candidates.count - 40) more.").font(.system(size: 11)).foregroundColor(.secondary)
                }
                findings("Kept", scan.kept)
            }
            if let last = monitor.lastTrashResult, last.step == step {
                findings("Kept at removal time", last.result.kept)
            }
        }
    }

    private var cachesCard: some View {
        card(.caches, icon: "shippingbox") {
            Text("Clears tool caches with each tool's own command; they refill on demand. A cache is kept while a program that uses it runs. Modules and crates download again on the next build.")
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Check caches") { monitor.scan(.caches) }
                    .disabled(monitor.isBusy || !allowsOperations)
                busyIndicator(.caches)
            }
            if let caches = monitor.caches {
                if caches.isEmpty { Text("No supported caches were found.").font(.system(size: 11)).foregroundColor(.secondary) }
                ForEach(caches) { cache in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cache.cache.title).font(.system(size: 12, weight: .medium))
                            Text(cache.blocker.map { "Kept: \($0)" } ?? cache.cache.note ?? MaintenancePath.abbreviate(cache.cache.paths[0], home: monitor.home))
                                .font(.system(size: 10)).foregroundColor(cache.blocker == nil ? .secondary : .orange)
                        }
                        Spacer()
                        Text(formatBytes(cache.sizeBytes)).font(.system(size: 11, design: .monospaced))
                        Button("Clear…") { confirmation = .clearCache(cache) }
                            .controlSize(.small)
                            .disabled(cache.blocker != nil || monitor.isBusy || !allowsOperations)
                    }
                }
            }
        }
    }

    private var trashCard: some View {
        card(.trash, icon: "trash") {
            Text("Everything above goes to the Trash, so it stays recoverable until you empty it here or in Finder. Emptying asks Finder, which may need Automation permission.")
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Count items") { monitor.scan(.trash) }
                    .disabled(monitor.isBusy || !allowsOperations)
                Button("Empty Trash…", role: .destructive) { confirmation = .emptyTrash(monitor.trashItemCount) }
                    .disabled(monitor.isBusy || monitor.trashItemCount == 0 || !allowsOperations)
                busyIndicator(.trash)
                Spacer()
                if let count = monitor.trashItemCount {
                    Text("\(count) item(s) in the Trash").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
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
            Text("Automatic emptying permanently deletes everything in the Trash, including items you moved there yourself. If KillSwitch was closed when it was due, it runs shortly after KillSwitch starts. Finder can also remove items after 30 days in its own settings.")
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
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
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Text(entry.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).frame(width: 64, alignment: .leading)
                        Text(entry.task).font(.system(size: 11))
                        if entry.mode == "scheduled" { StatusBadge(title: "Automatic", color: Theme.accent) }
                        Spacer()
                        Text(entry.note == MaintenanceRunSummary.spaceFreedNote ? "\(formatBytes(entry.trashedBytes)) freed"
                             : entry.note == MaintenanceRunSummary.spaceUnavailableNote ? "space change unavailable"
                             : "\(entry.trashedCount) item(s), \(formatBytes(entry.trashedBytes))")
                            .font(.system(size: 11, design: .monospaced))
                        if entry.errorCount > 0 { StatusBadge(title: "\(entry.errorCount) error(s)", color: .orange) }
                    }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Maintenance roots", systemImage: "folder.badge.gearshape")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.accent)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
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

    private func card<Content: View>(_ step: MaintenanceMonitor.Step, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(step.title, systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.accent)
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
    private func findings(_ title: String, _ items: [MaintenanceFinding]) -> some View {
        if !items.isEmpty {
            DisclosureGroup("\(title) (\(items.count))") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items.prefix(200)) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(MaintenancePath.abbreviate(finding.path, home: monitor.home))
                                .font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: 380, alignment: .leading)
                                .help(finding.path)
                            Text(finding.reason).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                    if items.count > 200 { Text("And \(items.count - 200) more.").font(.system(size: 10)).foregroundColor(.secondary) }
                }
                .textSelection(.enabled)
            }
            .font(.system(size: 11))
        }
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
