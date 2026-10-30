import Darwin
import Foundation
import InstallCore
import SwiftUI
import SystemMetricsCore
import os

final class ProcessInspectionMonitor: ObservableObject {
    enum Mode { case files, connections }
    @Published private(set) var files: [OpenFileRecord] = []
    @Published private(set) var connections: [NetworkConnectionRecord] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    private let queue = DispatchQueue(label: "killswitch.process-inspection", qos: .utility)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "process-inspection")
    private var timer: DispatchSourceTimer?
    private var mode: Mode = .files

    func start(_ mode: Mode) {
        queue.async { [self] in
            self.mode = mode
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 10, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.sample() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    func refresh() { queue.async { self.sample() } }

    private func sample() {
        DispatchQueue.main.async { self.isRefreshing = true }
        do {
            var arguments = ["-nP", "-b", "+c", "0", "-F0pcuLfatDinsPT"]
            if mode == .connections { arguments += ["-i", "-U"] }
            let result = try CommandRunner.run(
                "/usr/sbin/lsof", arguments: arguments, environment: ["LC_ALL": "en_US.UTF-8"]
            )
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.succeeded || (result.status == 1 && (detail.isEmpty || !result.standardOutput.isEmpty)) else {
                throw CommandRunnerError.commandFailed(executable: "lsof", status: result.status, message: detail)
            }
            let snapshot = ProcessInspectionParser.parseLsof(Data(result.standardOutput.utf8))
            DispatchQueue.main.async {
                self.files = snapshot.files
                self.connections = snapshot.connections
                self.lastUpdated = Date()
                self.errorMessage = detail.isEmpty ? nil : "Some entries may be inaccessible: \(detail)"
                self.isRefreshing = false
            }
        } catch {
            logger.error("Process inspection failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.errorMessage = error.localizedDescription
                self.isRefreshing = false
            }
        }
    }
}

struct OpenFilesPanel: View {
    let showAllUsers: Bool
    @StateObject private var monitor = ProcessInspectionMonitor()
    @State private var search = ""
    @State private var locksOnly = false
    @State private var kind = "All types"
    @State private var sort: OpenFileSort = .path
    @State private var ascending = true
    @State private var selected: OpenFileRecord.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Search path, process, PID, user, or lock", text: $search)
                    .textFieldStyle(.roundedBorder)
                Toggle("Reported locks", isOn: $locksOnly)
                    .toggleStyle(.checkbox)
                Picker("Type", selection: $kind) {
                    Text("All types").tag("All types")
                    Text("Regular files").tag("REG")
                    Text("Directories").tag("DIR")
                    Text("Unix sockets").tag("unix")
                }.frame(width: 160)
                Picker("Sort", selection: $sort) {
                    ForEach(OpenFileSort.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 150)
                SortDirectionButton(ascending: $ascending)
                inspectionRefresh(monitor)
            }

            InspectionStatus(monitor: monitor, count: visible.count, noun: "open files")
            Table(visible, selection: $selected) {
                TableColumn("Path") { Text($0.path).help($0.path) }
                    .width(min: 230, ideal: 360)
                TableColumn("Process") { Text($0.process) }
                    .width(min: 110, ideal: 150)
                TableColumn("PID") { Text(String($0.pid)) }.width(55)
                TableColumn("User") { Text($0.user) }.width(95)
                TableColumn("FD") { Text($0.descriptor) }.width(45)
                TableColumn("Access") { Text($0.accessDescription) }.width(85)
                TableColumn("Lock") { Text($0.lockDescription) }.width(110)
                TableColumn("Type") { Text($0.kind) }.width(55)
                TableColumn("Size") { Text($0.size.map(formatBytes) ?? "N/A") }.width(90)
            }
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .overlay {
                if visible.isEmpty && !monitor.isRefreshing {
                    Text(monitor.lastUpdated == nil ? "Refresh to inspect open files" : "No matching open files")
                        .foregroundColor(.secondary)
                }
            }
            if let file = monitor.files.first(where: { $0.id == selected }) {
                Text("\(file.process) (PID \(file.pid)), \(file.descriptor): \(file.path)")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text("Open does not mean locked. Lock fields are best-effort advisory locks, not proof that no other lock exists. Protected entries may be omitted; control characters in paths use lsof display escapes. This view never closes files or terminates processes.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .onAppear { monitor.start(.files) }
        .onDisappear { monitor.stop() }
    }

    private var visible: [OpenFileRecord] {
        OpenFileQuery(
            search: search, userID: showAllUsers ? nil : getuid(), locksOnly: locksOnly,
            kind: kind == "All types" ? nil : kind, sort: sort, ascending: ascending
        ).apply(to: monitor.files)
    }
}

struct NetworkConnectionsPanel: View {
    let showAllUsers: Bool
    @StateObject private var monitor = ProcessInspectionMonitor()
    @State private var search = ""
    @State private var filter: NetworkConnectionFilter = .all
    @State private var sort: NetworkConnectionSort = .process
    @State private var ascending = true
    @State private var selected: NetworkConnectionRecord.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search process, PID, endpoint, port, or state", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("Connection state", selection: $filter) {
                    ForEach(NetworkConnectionFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Picker("Sort", selection: $sort) {
                    ForEach(NetworkConnectionSort.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 160)
                SortDirectionButton(ascending: $ascending)
                inspectionRefresh(monitor)
            }
            InspectionStatus(monitor: monitor, count: visible.count, noun: "connections")
            Table(visible, selection: $selected) {
                TableColumn("Process") { Text($0.process) }.width(min: 110, ideal: 140)
                TableColumn("PID") { Text(String($0.pid)) }.width(55)
                TableColumn("User") { Text($0.user) }.width(90)
                TableColumn("Protocol") { Text("\($0.protocolName) \($0.family == "unix" ? "" : $0.family)") }.width(90)
                TableColumn("Local endpoint") { Text($0.local).help($0.local) }.width(min: 150, ideal: 200)
                TableColumn("Remote endpoint") { Text($0.remote ?? "None").help($0.remote ?? "No remote endpoint") }
                    .width(min: 150, ideal: 200)
                TableColumn("State") { Text($0.state) }.width(125)
            }
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .overlay {
                if visible.isEmpty && !monitor.isRefreshing {
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
        .onAppear { monitor.start(.connections) }
        .onDisappear { monitor.stop() }
    }

    private var visible: [NetworkConnectionRecord] {
        NetworkConnectionQuery(
            search: search, userID: showAllUsers ? nil : getuid(), filter: filter, sort: sort, ascending: ascending
        ).apply(to: monitor.connections)
    }
}

struct SortDirectionButton: View {
    @Binding var ascending: Bool
    var body: some View {
        Button { ascending.toggle() } label: {
            Image(systemName: ascending ? "arrow.up" : "arrow.down")
        }
        .help(ascending ? "Ascending; click for descending" : "Descending; click for ascending")
        .accessibilityLabel(ascending ? "Sort ascending" : "Sort descending")
    }
}

private struct InspectionStatus: View {
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

private func inspectionRefresh(_ monitor: ProcessInspectionMonitor) -> some View {
    Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
        .disabled(monitor.isRefreshing)
        .help("Refresh now")
        .accessibilityLabel("Refresh process inspection")
}
