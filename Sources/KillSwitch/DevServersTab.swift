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
        let groups = serverGroups
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Dev servers", systemImage: "server.rack")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                ProcessScopePicker(monitor: resourceMonitor)
                InspectionRefreshButton(monitor: monitor)
            }
            Text("Local TCP listeners, grouped by project or working directory. Read-only.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            TableSearchControls(
                search: $search, fields: ConnectionTableFields.all, prompt: "Search listeners, or port = 3000",
                resetAdditional: { projectSearch = ""; resourceMonitor.showAllUsers = false }
            )
            HStack {
                TextField("Find project, path, or branch", text: $projectSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                TableSortControls(fields: ConnectionTableFields.all, sorting: $sorting)
                Spacer()
            }
            InspectionStatus(monitor: monitor, count: groups.reduce(0) { $0 + $1.connections.count }, noun: "listeners")
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
                    Text(monitor.lastUpdated == nil ? "Collecting local listeners" : "No matching listeners")
                        .foregroundColor(.secondary)
                }
            }
            Text("Opening this page never starts cleanup or terminates processes. Not every TCP listener is HTTP. Project context refreshes at most every 30 seconds; listeners refresh every 10 seconds while visible. No git, Docker, or shell commands are executed for project discovery.")
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

    private var serverGroups: [ServerGroup] {
        let rows = sorting.sorted(
            NetworkConnectionQuery(search: search, userID: showAllUsers ? nil : getuid(), filter: .listening)
                .matching(monitor.connections),
            identity: \.id
        )
        let grouped = Dictionary(grouping: rows) { connection in
            monitor.identities[connection.pid].flatMap { monitor.projects[$0]?.directory.path } ?? "pid:\(connection.pid)"
        }
        return grouped.map { key, connections in
            ServerGroup(
                id: key,
                project: connections.first.flatMap { monitor.identities[$0.pid] }.flatMap { monitor.projects[$0] },
                connections: connections
            )
        }.filter { group in
            projectSearch.isEmpty || [group.project?.name, group.project?.directory.path, group.project?.branch]
                .compactMap { $0 }.contains { $0.localizedStandardContains(projectSearch) }
        }.sorted {
            let first = $0.project?.name ?? $0.id
            let second = $1.project?.name ?? $1.id
            return first == second ? $0.id < $1.id : first.localizedStandardCompare(second) == .orderedAscending
        }
    }
}
