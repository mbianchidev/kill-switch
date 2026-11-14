import AppKit
import Darwin
import SwiftUI
import SystemMetricsCore
import TableQueryCore

struct ConnectionsTab: View {
    let resourceMonitor: ResourceMonitor
    @State private var showAllUsers: Bool

    init(resourceMonitor: ResourceMonitor) {
        self.resourceMonitor = resourceMonitor
        _showAllUsers = State(initialValue: resourceMonitor.showAllUsers)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Connections", systemImage: "network").font(.system(size: 17, weight: .semibold))
                Spacer()
                ProcessScopePicker(monitor: resourceMonitor)
            }
            .padding(16)
            Divider()
            NetworkConnectionsPanel(showAllUsers: Binding(
                get: { showAllUsers }, set: { resourceMonitor.showAllUsers = $0 }
            ))
        }
        .background(Theme.background)
        .onReceive(resourceMonitor.$showAllUsers.removeDuplicates()) { showAllUsers = $0 }
    }
}

struct DevServersTab: View {
    let resourceMonitor: ResourceMonitor
    @StateObject private var monitor = ProcessInspectionMonitor()
    @State private var showAllUsers: Bool
    @State private var search = ""
    @State private var projectSearch = ""
    @State private var showAllListeners = false
    @State private var sorting = TableComparator(field: ConnectionTableFields.local)
    @State private var revealError: String?
    @Environment(\.allowsLiveOperations) private var allowsOperations
    @Environment(\.isKillSwitchPageVisible) private var pageVisible

    init(resourceMonitor: ResourceMonitor) {
        self.resourceMonitor = resourceMonitor
        _showAllUsers = State(initialValue: resourceMonitor.showAllUsers)
    }

    var body: some View {
        Group {
            if pageVisible { pageContent }
        }
    }

    private var pageContent: some View {
        let listeners = matchingListeners
        let detection = monitor.devServerDetection
        let rows = showAllListeners ? listeners : listeners.filter { detection.listenerIDs.contains($0.id) }
        let hiddenUnclassified = showAllListeners ? 0 : listeners.lazy.filter {
            detection.unclassifiedListenerIDs.contains($0.id) && !detection.listenerIDs.contains($0.id)
        }.count
        let groups = Self.serverGroups(rows, identities: monitor.identities, projects: monitor.projects)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Dev servers", systemImage: "server.rack")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                ProcessScopePicker(monitor: resourceMonitor)
                InspectionRefreshButton(monitor: monitor)
            }
            Text(showAllListeners
                 ? "All local TCP listeners, grouped by project or working directory. Read-only."
                 : "Dev servers and watched ports detected with your Dev cleanup rules, grouped by project or working directory. Read-only.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            TableSearchControls(
                search: $search, fields: ConnectionTableFields.all, prompt: "Search listeners, or port = 3000",
                resetAdditional: { projectSearch = ""; showAllListeners = false; resourceMonitor.showAllUsers = false }
            )
            HStack {
                TextField("Find project, path, or branch", text: $projectSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                TableSortControls(fields: ConnectionTableFields.all, sorting: $sorting)
                Spacer()
                Picker("Show", selection: $showAllListeners) {
                    Text("Detected dev servers").tag(false)
                    Text("All listeners").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Detected dev servers use the same runtimes, indicators, exclusions, and watched ports as Dev cleanup.")
            }
            InspectionStatus(monitor: monitor, count: rows.count, noun: showAllListeners ? "listeners" : "detected dev servers")
            if hiddenUnclassified > 0 {
                Label(
                    "\(hiddenUnclassified) listener(s) are hidden because their command lines were unavailable, so they could only match watched ports. Choose All listeners to review them."
                        + (detection.error.map { " \($0)" } ?? ""),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .textSelection(.enabled)
            }
            if Self.hasProjectWarnings(
                in: groups.lazy.flatMap(\.connections), identities: monitor.identities, errors: monitor.projectErrors
            ) {
                Label("Some project details are unavailable. The affected rows explain why.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.project?.name ?? "Working directory unavailable")
                                        .font(.system(size: 14, weight: .semibold))
                                    if let project = group.project {
                                        Text(project.directory.path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .help(project.directory.path)
                                        Text(project.branch ?? "No Git branch available")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if let project = group.project {
                                    Button("Reveal folder") {
                                        var isDirectory: ObjCBool = false
                                        guard FileManager.default.fileExists(atPath: project.directory.path, isDirectory: &isDirectory),
                                              isDirectory.boolValue else {
                                            revealError = "The project folder is no longer available."
                                            fputs("KillSwitch could not reveal an unavailable development project folder.\n", stderr)
                                            return
                                        }
                                        NSWorkspace.shared.activateFileViewerSelecting([project.directory])
                                    }
                                    .disabled(!allowsOperations)
                                }
                            }
                            ForEach(group.connections) { connection in
                                Divider()
                                listener(connection)
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                    }
                }
            }
            .overlay {
                if groups.isEmpty && !monitor.isRefreshing {
                    Text(monitor.lastUpdated == nil ? "Collecting local listeners"
                         : showAllListeners || listeners.isEmpty ? "No matching listeners"
                         : "No detected dev servers. Choose All listeners to see every TCP listener.")
                        .foregroundColor(.secondary)
                }
            }
            Text("Opening this page never starts cleanup or terminates processes. Not every TCP listener is HTTP. Project context refreshes at most every 30 seconds; listeners refresh every 10 seconds while visible. Detection reads listener command lines with ps; no git, Docker, or shell commands are executed for project discovery.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(Theme.background)
        .onReceive(resourceMonitor.$showAllUsers.removeDuplicates()) { showAllUsers = $0 }
        .inspectionSampling(monitor, mode: .listeners)
        .alert("Could not reveal folder", isPresented: Binding(
            get: { revealError != nil }, set: { if !$0 { revealError = nil } }
        )) { Button("OK") { revealError = nil } } message: { Text(revealError ?? "") }
    }

    private func listener(_ connection: NetworkConnectionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.process).font(.system(size: 12, weight: .medium))
                    Text("PID \(connection.pid) / \(connection.user) / \(connection.protocolDescription)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(connection.local).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                OpenListenerButton(connection: connection)
                CopyInspectionTextButton(title: "Copy address", value: connection.local)
                InspectProcessButton(process: monitor.descriptor(pid: connection.pid, name: connection.process, user: connection.user))
            }
            if let identity = monitor.identities[connection.pid], let error = monitor.projectErrors[identity] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    static func hasProjectWarnings<Rows: Sequence>(
        in rows: Rows, identities: [Int32: ActivityProcessIdentity], errors: [ActivityProcessIdentity: String]
    ) -> Bool where Rows.Element == NetworkConnectionRecord {
        rows.contains { connection in
            identities[connection.pid].map { errors[$0] != nil } ?? false
        }
    }

    private struct ServerGroup: Identifiable {
        let id: String
        let project: DevelopmentProjectContext?
        let connections: [NetworkConnectionRecord]
    }

    /// Listeners matching the user scope, table search, and project search, before dev server detection.
    private var matchingListeners: [NetworkConnectionRecord] {
        sorting.sorted(
            NetworkConnectionQuery(search: search, userID: showAllUsers ? nil : getuid(), filter: .listening)
                .matching(monitor.connections),
            identity: \.id
        ).filter { connection in
            guard !projectSearch.isEmpty else { return true }
            let project = monitor.identities[connection.pid].flatMap { monitor.projects[$0] }
            return [project?.name, project?.directory.path, project?.branch]
                .compactMap { $0 }.contains { $0.localizedStandardContains(projectSearch) }
        }
    }

    private static func serverGroups(
        _ rows: [NetworkConnectionRecord], identities: [Int32: ActivityProcessIdentity],
        projects: [ActivityProcessIdentity: DevelopmentProjectContext]
    ) -> [ServerGroup] {
        let grouped = Dictionary(grouping: rows) { connection in
            identities[connection.pid].flatMap { projects[$0]?.directory.path } ?? "pid:\(connection.pid)"
        }
        return grouped.map { key, connections in
            ServerGroup(
                id: key,
                project: connections.first.flatMap { identities[$0.pid] }.flatMap { projects[$0] },
                connections: connections
            )
        }.sorted {
            let first = $0.project?.name ?? $0.id
            let second = $1.project?.name ?? $1.id
            return first == second ? $0.id < $1.id : first.localizedStandardCompare(second) == .orderedAscending
        }
    }
}
