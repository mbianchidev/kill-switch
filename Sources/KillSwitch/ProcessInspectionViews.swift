import Combine
import Darwin
import Foundation
import InstallCore
import SwiftUI
import SystemMetricsCore
import TableQueryCore
import os

final class ProcessInspectionMonitor: ObservableObject {
    enum Mode: Sendable { case files, connections, listeners }
    @Published private(set) var files: [OpenFileRecord] = []
    @Published private(set) var connections: [NetworkConnectionRecord] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var identities: [Int32: ActivityProcessIdentity] = [:]
    @Published private(set) var projects: [ActivityProcessIdentity: DevelopmentProjectContext] = [:]
    @Published private(set) var projectErrors: [ActivityProcessIdentity: String] = [:]
    private let queue = DispatchQueue(
        label: "killswitch.process-inspection", qos: .utility, autoreleaseFrequency: .workItem
    )
    private let logger = Logger(subsystem: "com.killswitch.app", category: "process-inspection")
    private var timer: DispatchSourceTimer?
    private var mode: Mode = .files
    private let target: ActivityProcessIdentity?
    private var activationID: UUID?
    private struct CachedProject {
        let date: Date
        let project: DevelopmentProjectContext?
        let error: String?
    }
    private var projectCache: [ActivityProcessIdentity: CachedProject] = [:]

    init(target: ActivityProcessIdentity? = nil) {
        self.target = target
#if KILLSWITCH_PERFORMANCE_PROBE
        restorePerformanceFixture()
#endif
    }

#if KILLSWITCH_PERFORMANCE_PROBE
    func restorePerformanceFixture() {
        let fixture = Self.performanceFixture
        files = fixture.files.filter { target == nil || $0.pid == target?.pid }
        connections = fixture.connections.filter { target == nil || $0.pid == target?.pid }
        identities = Self.performanceIdentities
        projects = Dictionary(uniqueKeysWithValues: identities.values.map { identity in
            (identity, DevelopmentProjectContext(
                directory: URL(fileURLWithPath: "/synthetic/project-\((identity.pid - 100_000) / 50)", isDirectory: true),
                branch: "synthetic-feature"
            ))
        })
        lastUpdated = Date()
    }
#endif

    func start(_ mode: Mode) {
        dispatchPrecondition(condition: .onQueue(.main))
        let id = UUID()
        activationID = id
        self.mode = mode
        queue.async { [self] in
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 10, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.sample(mode: mode, activation: id) }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        activationID = nil
        isRefreshing = false
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.projectCache.removeAll()
            DispatchQueue.main.async {
                guard self.activationID == nil else { return }
                self.files = []
                self.connections = []
                self.identities = [:]
                self.projects = [:]
                self.projectErrors = [:]
                self.lastUpdated = nil
            }
        }
    }

    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let id = activationID, !isRefreshing else { return }
        isRefreshing = true
        let mode = mode
        queue.async { self.sample(mode: mode, activation: id) }
    }

    func descriptor(pid: Int32, name: String, user: String) -> ActivityProcessDescriptor? {
        identities[pid].map { ActivityProcessDescriptor(identity: $0, name: name, user: user) }
    }

    private func sample(mode: Mode, activation: UUID) {
        DispatchQueue.main.async {
            if self.activationID == activation { self.isRefreshing = true }
        }
        do {
#if KILLSWITCH_PERFORMANCE_PROBE
            let snapshot = Self.performanceFixture
            let verified = Self.performanceIdentities
            let detail = ""
#else
            let before: [Int32: ActivityProcessIdentity]
            if let target {
                try ProcessLifetimeReader.validate(target, presence: ProcessLifetimeReader.presence(
                    pid: target.pid, bootSession: target.bootSession
                ))
                before = [target.pid: target]
            } else { before = try ProcessLifetimeReader.snapshot() }
            let arguments = try ProcessInspectionParser.arguments(
                pid: target?.pid, connectionsOnly: mode == .connections, listenersOnly: mode == .listeners
            )
            let result = try CommandRunner.run(
                "/usr/sbin/lsof", arguments: arguments, environment: ["LC_ALL": "en_US.UTF-8"]
            )
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.succeeded || (result.status == 1 && (detail.isEmpty || !result.standardOutput.isEmpty)) else {
                throw CommandRunnerError.commandFailed(executable: "lsof", status: result.status, message: detail)
            }
            let snapshot = ProcessInspectionParser.parseLsof(Data(result.standardOutput.utf8))
            if let target {
                try ProcessLifetimeReader.validate(target, presence: ProcessLifetimeReader.presence(
                    pid: target.pid, bootSession: target.bootSession
                ))
            }
            let pids = Set(snapshot.files.map(\.pid) + snapshot.connections.map(\.pid))
            var verified: [Int32: ActivityProcessIdentity] = [:]
            for pid in pids {
                if let expected = before[pid],
                   ProcessLifetimeReader.presence(pid: pid, bootSession: expected.bootSession) == .present(expected) {
                    verified[pid] = expected
                }
            }
#endif
            var projects: [ActivityProcessIdentity: DevelopmentProjectContext] = [:]
            var projectErrors: [ActivityProcessIdentity: String] = [:]
            if mode == .listeners {
                let now = Date()
                let activeIdentities = Set(verified.values)
                projectCache = projectCache.filter { activeIdentities.contains($0.key) }
                for identity in verified.values {
                    let result: CachedProject
                    if let cached = projectCache[identity], now.timeIntervalSince(cached.date) < 30 {
                        result = cached
                    } else {
#if KILLSWITCH_PERFORMANCE_PROBE
                        result = CachedProject(date: now, project: DevelopmentProjectContext(
                            directory: URL(fileURLWithPath: "/synthetic/project-\((identity.pid - 100_000) / 50)", isDirectory: true),
                            branch: "synthetic-feature"
                        ), error: nil)
#else
                        do {
                            let directory = try ProcessWorkingDirectoryReader.read(identity)
                            do {
                                result = CachedProject(
                                    date: now, project: try DevelopmentProjectResolver.resolve(directory), error: nil
                                )
                            } catch {
                                result = CachedProject(
                                    date: now, project: DevelopmentProjectContext(directory: directory, branch: nil),
                                    error: "Project discovery is incomplete; showing the verified working directory. \(error.localizedDescription)"
                                )
                            }
                        } catch {
                            result = CachedProject(date: now, project: nil, error: error.localizedDescription)
                        }
#endif
                        projectCache[identity] = result
                    }
                    if let project = result.project { projects[identity] = project }
                    if let error = result.error { projectErrors[identity] = error }
                }
            }
            DispatchQueue.main.async {
                guard self.activationID == activation else { return }
                self.files = mode == .files ? snapshot.files.filter { self.target == nil || $0.pid == self.target?.pid } : []
                self.connections = snapshot.connections.filter { self.target == nil || $0.pid == self.target?.pid }
                self.identities = verified
                self.projects = projects
                self.projectErrors = projectErrors
                self.lastUpdated = Date()
                self.errorMessage = detail.isEmpty ? nil : "Some entries may be inaccessible: \(detail)"
                self.isRefreshing = false
            }
        } catch {
            logger.error("Process inspection failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                guard self.activationID == activation else { return }
                self.errorMessage = error.localizedDescription
                self.isRefreshing = false
                if self.target != nil {
                    self.files = []
                    self.connections = []
                    self.identities = [:]
                }
            }
        }
    }

#if KILLSWITCH_PERFORMANCE_PROBE
    private static let performanceFixture: ProcessInspectionSnapshot = {
        let fields = (0..<1_000).flatMap { index in
            [
                "p\(100_000 + index)", "cSynthetic server \(index)", "u501", "Lsynthetic-user",
                "\nf4", "tREG", "ar", "s4096", "n/synthetic/project-\(index / 50)/fixture.txt",
                "\nf5", "tIPv4", "PTCP", "n127.0.0.1:\(3_000 + index)", "TST=LISTEN"
            ]
        } + [""]
        return ProcessInspectionParser.parseLsof(Data(fields.joined(separator: "\0").utf8))
    }()

    private static let performanceIdentities: [Int32: ActivityProcessIdentity] = {
        var identities: [Int32: ActivityProcessIdentity] = [:]
        for index in 0..<1_000 {
            let pid = Int32(100_000 + index)
            identities[pid] = ActivityProcessIdentity(
                bootSession: "synthetic-benchmark-boot", pid: pid, startTime: UInt64(index + 1)
            )
        }
        return identities
    }()
#endif
}

struct OpenFilesTab: View {
    let resourceMonitor: ResourceMonitor
    @StateObject private var monitor = ProcessInspectionMonitor()
    @State private var showAllUsers: Bool
    @State private var search = ""
    @State private var locksOnly = false
    @State private var kind = "All types"
    @State private var sorting = TableComparator(field: OpenFileTableFields.path)
    @State private var selected: OpenFileRecord.ID?

    init(resourceMonitor: ResourceMonitor) {
        self.resourceMonitor = resourceMonitor
        _showAllUsers = State(initialValue: resourceMonitor.showAllUsers)
    }

    var body: some View {
        let rows = visible
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label("Open files", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                ProcessScopePicker(monitor: resourceMonitor)
            }
            Divider()
            TableSearchControls(
                search: $search, fields: OpenFileTableFields.all, prompt: "Search files, or size > 1MB",
                resetAdditional: {
                    locksOnly = false
                    kind = "All types"
                    resourceMonitor.showAllUsers = false
                }
            )
            HStack(spacing: 10) {
                Toggle("Reported locks", isOn: $locksOnly)
                    .toggleStyle(.checkbox)
                Picker("Type", selection: $kind) {
                    Text("All types").tag("All types")
                    Text("Regular files").tag("REG")
                    Text("Directories").tag("DIR")
                    Text("Unix sockets").tag("unix")
                }.frame(width: 160)
                TableSortControls(fields: OpenFileTableFields.columns, sorting: $sorting)
                Spacer()
                InspectionRefreshButton(monitor: monitor)
            }

            InspectionStatus(monitor: monitor, count: rows.count, noun: "open files")
            OpenFilesTable(rows: rows, identities: monitor.identities, selection: $selected, sorting: $sorting)
            .overlay {
                if rows.isEmpty && !monitor.isRefreshing {
                    Text(monitor.lastUpdated == nil ? "Refresh to inspect open files" : "No matching open files")
                        .foregroundColor(.secondary)
                }
            }
            if let file = monitor.files.first(where: { $0.id == selected }) {
                HStack {
                    Text("\(file.process) (PID \(file.pid)), \(file.descriptor): \(file.path)")
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    CopyInspectionTextButton(title: "Copy displayed path", value: file.path)
                }
            }
            Text("Open does not mean locked. macOS can omit advisory lock state; no reported lock does not prove a file is unlocked. Protected entries may be omitted; control characters in paths use lsof display escapes. This view never closes files or terminates processes.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Theme.background)
        .onReceive(resourceMonitor.$showAllUsers.removeDuplicates()) { showAllUsers = $0 }
        .inspectionSampling(monitor, mode: .files)
    }

    private var visible: [OpenFileRecord] {
        let query = OpenFileQuery(
            search: search, userID: showAllUsers ? nil : getuid(), locksOnly: locksOnly,
            kind: kind == "All types" ? nil : kind
        )
        return sorting.sorted(query.matching(monitor.files), identity: \.id)
    }
}

struct NetworkConnectionsPanel: View {
    @Binding var showAllUsers: Bool
    @StateObject private var monitor = ProcessInspectionMonitor()
    @State private var search = ""
    @State private var filter: NetworkConnectionFilter = .all
    @State private var sorting = TableComparator(field: ConnectionTableFields.process)
    @State private var selected: NetworkConnectionRecord.ID?

    var body: some View {
        let rows = visible
        return VStack(alignment: .leading, spacing: 10) {
            TableSearchControls(
                search: $search, fields: ConnectionTableFields.all, prompt: "Search connections, or port >= 8000",
                resetAdditional: { filter = .all; showAllUsers = false }
            )
            HStack {
                Picker("Connection state", selection: $filter) {
                    ForEach(NetworkConnectionFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                TableSortControls(fields: ConnectionTableFields.all, sorting: $sorting)
                Spacer()
                InspectionRefreshButton(monitor: monitor)
            }
            InspectionStatus(monitor: monitor, count: rows.count, noun: "connections")
            ConnectionsTable(rows: rows, identities: monitor.identities, selection: $selected, sorting: $sorting)
            .overlay {
                if rows.isEmpty && !monitor.isRefreshing {
                    Text(monitor.lastUpdated == nil ? "Collecting connections" : "No matching connections")
                        .foregroundColor(.secondary)
                }
            }
            if let connection = monitor.connections.first(where: { $0.id == selected }) {
                Text("\(connection.process) (PID \(connection.pid)): \(connection.local) -> \(connection.remote ?? "no remote endpoint") [\(connection.state)]")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text("TCP listeners, active connections, bound UDP sockets, and Unix sockets visible to this account. Addresses and ports are numeric. Refreshes every 10 seconds; short-lived connections between samples may not appear.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .inspectionSampling(monitor, mode: .connections)
    }

    private var visible: [NetworkConnectionRecord] {
        let query = NetworkConnectionQuery(search: search, userID: showAllUsers ? nil : getuid(), filter: filter)
        return sorting.sorted(query.matching(monitor.connections), identity: \.id)
    }
}

struct InspectionStatus: View {
    @ObservedObject var monitor: ProcessInspectionMonitor
    let count: Int
    let noun: String

    var body: some View {
        HStack {
            Text("\(count) \(noun)")
            if let date = monitor.lastUpdated {
                Text("Updated \(date.formatted(date: .omitted, time: .standard))")
            }
            if monitor.isRefreshing { ProgressView().controlSize(.mini) }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        if let error = monitor.errorMessage {
            DisclosureGroup {
                ScrollView {
                    Text(error)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 90)
            } label: {
                Label("Inspection reported a warning or error", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
            }
            .foregroundColor(.orange)
        }
    }
}
