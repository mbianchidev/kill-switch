import Combine
import Darwin
import DevCleanupCore
import Foundation
import InstallCore
import SwiftUI
import SystemMetricsCore
import TableQueryCore
import os

final class ProcessInspectionMonitor: ObservableObject {
    enum Mode: Sendable, Equatable { case files, connections, listeners }
    private struct InspectionIssue {
        let message: String
        let activationID: UUID
    }
    @Published private(set) var files: [OpenFileRecord] = []
    @Published private(set) var connections: [NetworkConnectionRecord] = []
    @Published private var issue: InspectionIssue?
    var errorMessage: String? { issue?.message }
    var errorIsFromPreviousActivation: Bool {
        issue.map { $0.activationID != activationID } ?? false
    }
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var identities: [Int32: ActivityProcessIdentity] = [:]
    @Published private(set) var projects: [ActivityProcessIdentity: DevelopmentProjectContext] = [:]
    @Published private(set) var projectErrors: [ActivityProcessIdentity: String] = [:]
    struct DevServerDetection: Equatable {
        /// Listeners matching Dev cleanup rules.
        var listenerIDs: Set<NetworkConnectionRecord.ID> = []
        /// Listeners without a lifetime-verified command line; they can only match watched ports.
        var unclassifiedListenerIDs: Set<NetworkConnectionRecord.ID> = []
        var error: String?
    }
    /// Populated in listeners mode only.
    @Published private(set) var devServerDetection = DevServerDetection()
    private lazy var devCleanupPreferences = DevCleanupPreferences()
    private let queue = DispatchQueue(
        label: "killswitch.process-inspection", qos: .utility, autoreleaseFrequency: .workItem
    )
    private let logger = Logger(subsystem: "com.killswitch.app", category: "process-inspection")
    private var timer: DispatchSourceTimer?
    private var mode: Mode = .files
    private let target: ActivityProcessIdentity?
    private var activationOwner: UUID?
    private let activation = OSAllocatedUnfairLock<UUID?>(initialState: nil)
    private var activationID: UUID? {
        get { activation.withLock { $0 } }
        set { activation.withLock { $0 = newValue } }
    }
    private struct CachedProject {
        let expiresAt: ContinuousClock.Instant
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
    private var performanceSamples: [Mode] = []
    private var performanceProjectReads = 0
    private var performanceProjectNow: ContinuousClock.Instant?
    private var performanceProjectWallDate: Date?
    var performanceSampleModes: [Mode] { queue.sync { performanceSamples } }
    var performanceProjectReadCount: Int { queue.sync { performanceProjectReads } }
    func performanceEnqueue(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    func performanceSetProjectTime(_ instant: ContinuousClock.Instant, date: Date) {
        dispatchPrecondition(condition: .onQueue(.main))
        queue.sync {
            performanceProjectNow = instant
            performanceProjectWallDate = date
        }
    }

    func performanceReportError(_ message: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let id = activationID else {
            preconditionFailure("A synthetic inspection error requires an active collection.")
        }
        issue = InspectionIssue(message: message, activationID: id)
        isRefreshing = false
    }

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
        devServerDetection = Self.classifyListeners(
            connections, commands: Self.performanceCommands, verified: identities,
            configuration: Self.performanceDevCleanupConfiguration
        )
        lastUpdated = Date()
    }
#endif

    func start(_ mode: Mode, owner: UUID = UUID()) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activationID == nil || activationOwner != owner || self.mode != mode else { return }
        let id = UUID()
        activationOwner = owner
        activationID = id
        self.mode = mode
        isRefreshing = true
        queue.async { [self] in
            guard self.activationID == id else { return }
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 10, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.sample(mode: mode, activation: id) }
            self.timer = timer
            timer.resume()
        }
    }

    func stop(owner: UUID? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard owner == nil || activationOwner == owner else { return }
        activationOwner = nil
        activationID = nil
        isRefreshing = false
        files = []
        connections = []
        identities = [:]
        projects = [:]
        projectErrors = [:]
        devServerDetection = DevServerDetection()
        lastUpdated = nil
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.projectCache.removeAll()
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

    private func finishRefresh(_ expected: UUID) {
        DispatchQueue.main.async {
            if self.activationID == expected { self.isRefreshing = false }
        }
    }

    private func continueCollection(_ expected: UUID) -> Bool {
        guard activationID == expected else { return false }
        guard AppWindowVisibility.isVisible else { finishRefresh(expected); return false }
        return true
    }

    private func sample(mode: Mode, activation: UUID) {
        guard continueCollection(activation) else { return }
#if KILLSWITCH_PERFORMANCE_PROBE
        performanceSamples.append(mode)
#endif
        DispatchQueue.main.async {
            if self.activationID == activation { self.isRefreshing = true }
        }
        do {
#if KILLSWITCH_PERFORMANCE_PROBE
            let snapshot = Self.performanceFixture
            let verified = Self.performanceIdentities
            let detail = ""
            let commands = Self.performanceCommands
            let commandError: String? = nil
#else
            let before: [Int32: ActivityProcessIdentity]
            if let target {
                try ProcessLifetimeReader.validate(target, presence: ProcessLifetimeReader.presence(
                    pid: target.pid, bootSession: target.bootSession
                ))
                before = [target.pid: target]
            } else { before = try ProcessLifetimeReader.snapshot() }
            guard continueCollection(activation) else { return }
            let arguments = try ProcessInspectionParser.arguments(
                pid: target?.pid, connectionsOnly: mode == .connections, listenersOnly: mode == .listeners
            )
            let result = try CommandRunner.run(
                "/usr/sbin/lsof", arguments: arguments, environment: ["LC_ALL": "en_US.UTF-8"]
            )
            guard continueCollection(activation) else { return }
            let standardError = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.succeeded || (result.status == 1 && (standardError.isEmpty || !result.standardOutput.isEmpty)) else {
                throw CommandRunnerError.commandFailed(executable: "lsof", status: result.status, message: standardError)
            }
            let snapshot = ProcessInspectionParser.parseLsof(Data(result.standardOutput.utf8))
            let diagnosticMessages = snapshot.diagnostics.keys.sorted().flatMap { pid in
                (snapshot.diagnostics[pid] ?? []).map { "PID \(pid): \($0)" }
            }
            let detail = ([standardError] + diagnosticMessages).filter { !$0.isEmpty }.joined(separator: "\n")
            if let target {
                try ProcessLifetimeReader.validate(target, presence: ProcessLifetimeReader.presence(
                    pid: target.pid, bootSession: target.bootSession
                ))
                try ProcessInspectionParser.validateTarget(snapshot, pid: target.pid)
            }
            var commands: [Int32: String] = [:]
            var commandError: String?
            if mode == .listeners {
                // Read before lifetime verification so verified PIDs bind these command lines to the same process.
                do {
                    commands = try ProcessSampler.commandLines(
                        pids: Set(snapshot.connections.lazy.filter(\.isListening).map(\.pid))
                    )
                } catch {
                    commandError = error.localizedDescription
                    logger.error("Dev server detection could not read command lines: \(error.localizedDescription)")
                }
                guard continueCollection(activation) else { return }
            }
            let pids = Set(snapshot.files.map(\.pid) + snapshot.connections.map(\.pid))
            var verified: [Int32: ActivityProcessIdentity] = [:]
            for pid in pids {
                guard continueCollection(activation) else { return }
                if let expected = before[pid],
                   ProcessLifetimeReader.presence(pid: pid, bootSession: expected.bootSession) == .present(expected) {
                    verified[pid] = expected
                }
            }
#endif
            guard continueCollection(activation) else { return }
            var projects: [ActivityProcessIdentity: DevelopmentProjectContext] = [:]
            var projectErrors: [ActivityProcessIdentity: String] = [:]
            if mode == .listeners {
#if KILLSWITCH_PERFORMANCE_PROBE
                let now = performanceProjectNow ?? .now
#else
                let now = ContinuousClock.now
#endif
                let expiresAt = now.advanced(by: .seconds(30))
                let activeIdentities = Set(verified.values)
                projectCache = projectCache.filter { activeIdentities.contains($0.key) }
                for identity in verified.values {
                    guard continueCollection(activation) else { return }
                    let result: CachedProject
                    if let cached = projectCache[identity], now < cached.expiresAt {
                        result = cached
                    } else {
#if KILLSWITCH_PERFORMANCE_PROBE
                        performanceProjectReads += 1
                        result = CachedProject(expiresAt: expiresAt, project: DevelopmentProjectContext(
                            directory: URL(fileURLWithPath: "/synthetic/project-\((identity.pid - 100_000) / 50)", isDirectory: true),
                            branch: "synthetic-feature"
                        ), error: nil)
#else
                        do {
                            let directory = try ProcessWorkingDirectoryReader.read(identity)
                            guard continueCollection(activation) else { return }
                            let lease = self.activation
                            do {
                                result = CachedProject(
                                    expiresAt: expiresAt, project: try DevelopmentProjectResolver.resolve(directory, shouldContinue: {
                                        lease.withLock { $0 == activation } && AppWindowVisibility.isVisible
                                    }), error: nil
                                )
                            } catch {
                                if error is CancellationError { throw error }
                                result = CachedProject(
                                    expiresAt: expiresAt, project: (error as? DevelopmentProjectMetadataError)?.project
                                        ?? DevelopmentProjectContext(directory: directory, branch: nil),
                                    error: "Project discovery is incomplete; showing the verified project or working directory. \(error.localizedDescription)"
                                )
                            }
                        } catch {
                            if error is CancellationError { throw error }
                            result = CachedProject(expiresAt: expiresAt, project: nil, error: error.localizedDescription)
                        }
#endif
                        projectCache[identity] = result
                    }
                    if let project = result.project { projects[identity] = project }
                    if let error = result.error { projectErrors[identity] = error }
                }
            }
            var detection = DevServerDetection()
            if mode == .listeners {
#if KILLSWITCH_PERFORMANCE_PROBE
                let configuration = Self.performanceDevCleanupConfiguration
#else
                let configuration = devCleanupPreferences.load().configuration(allowAutomaticTermination: false)
#endif
                detection = Self.classifyListeners(
                    snapshot.connections, commands: commands, verified: verified, configuration: configuration
                )
                detection.error = commandError
            }
#if KILLSWITCH_PERFORMANCE_PROBE
            let updatedAt = performanceProjectWallDate ?? Date()
#endif
            DispatchQueue.main.async {
                guard self.activationID == activation else { return }
                guard AppWindowVisibility.isVisible else { self.isRefreshing = false; return }
                self.files = mode == .files ? snapshot.files.filter { self.target == nil || $0.pid == self.target?.pid } : []
                self.connections = snapshot.connections.filter { self.target == nil || $0.pid == self.target?.pid }
                self.identities = verified
                self.projects = projects
                self.projectErrors = projectErrors
                self.devServerDetection = detection
#if KILLSWITCH_PERFORMANCE_PROBE
                self.lastUpdated = updatedAt
#else
                self.lastUpdated = Date()
#endif
                self.issue = detail.isEmpty ? nil : InspectionIssue(
                    message: "Some entries may be inaccessible: \(detail)", activationID: activation
                )
                self.isRefreshing = false
            }
        } catch {
            if error is CancellationError { finishRefresh(activation); return }
            guard continueCollection(activation) else { return }
            logger.error("Process inspection failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                guard self.activationID == activation else { return }
                guard AppWindowVisibility.isVisible else { self.isRefreshing = false; return }
                self.issue = InspectionIssue(message: error.localizedDescription, activationID: activation)
                self.isRefreshing = false
                if self.target != nil {
                    self.files = []
                    self.connections = []
                    self.identities = [:]
                }
            }
        }
    }

    static func classifyListeners(
        _ connections: [NetworkConnectionRecord], commands: [Int32: String],
        verified: [Int32: ActivityProcessIdentity], configuration: DevCleanupConfiguration
    ) -> DevServerDetection {
        let classifier = DevServerClassifier(configuration: configuration)
        var detection = DevServerDetection()
        for connection in connections where connection.isListening {
            // Only a lifetime-verified PID proves that the command line belongs to this listener.
            let command = verified[connection.pid] == nil ? nil : commands[connection.pid]
            if command == nil { detection.unclassifiedListenerIDs.insert(connection.id) }
            if let port = connection.localPort, classifier.listsListener(command: command, port: Int(port)) {
                detection.listenerIDs.insert(connection.id)
            }
        }
        return detection
    }

#if KILLSWITCH_PERFORMANCE_PROBE
    static let performanceNonDevServerPID: Int32 = 100_999
    private static let performanceCommands: [Int32: String] = Dictionary(
        uniqueKeysWithValues: performanceIdentities.keys.map { pid in
            (pid, pid == performanceNonDevServerPID
                ? "/usr/local/bin/synthetic-daemon --listen"
                : "/usr/local/bin/node /synthetic/project-\((pid - 100_000) / 50)/node_modules/.bin/vite")
        }
    )
    static let performanceDevCleanupConfiguration = DevCleanupConfiguration(
        autoKillEnabled: false, ageThresholdSeconds: 0, effectivePorts: DevCleanupDefaults.ports,
        runtimes: DevCleanupDefaults.runtimes, indicators: DevCleanupDefaults.indicators,
        exclusions: DevCleanupDefaults.exclusions
    )

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
    @Environment(\.isKillSwitchPageVisible) private var pageVisible

    var body: some View {
        Group {
            if pageVisible { pageContent }
        }
    }

    private var pageContent: some View {
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

    var issueLabel: String {
        monitor.errorIsFromPreviousActivation
            ? "Previous inspection warning or error"
            : "Inspection reported a warning or error"
    }

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
                Label(issueLabel, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
            }
            .foregroundColor(.orange)
        }
    }
}
