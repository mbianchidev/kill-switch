import AppKit
import Darwin
import Foundation
import StartupCore
import SwiftUI
import os

final class StartupMonitor: ObservableObject {
    @Published private(set) var items: [StartupItem] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isWorking = false
    @Published private(set) var includesLoginApps = false
    @Published private(set) var includesSystemCron = false
    private let queue = DispatchQueue(label: "killswitch.startup", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "startup")
    private let service: StartupService

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        service = StartupService(
            home: home, currentUID: getuid(),
            stateDirectory: home.appendingPathComponent("Library/Application Support/KillSwitch/StartupBackups")
        )
    }

    func refresh(loadLoginApps: Bool = false, loadSystemCron: Bool = false) {
        guard !isWorking else { return }
        includesLoginApps = includesLoginApps || loadLoginApps
        includesSystemCron = includesSystemCron || loadSystemCron
        let login = includesLoginApps
        let cron = includesSystemCron
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        queue.async {
            let snapshot = self.service.scan(includeLoginApps: login, includeSystemCron: cron)
            self.publish(snapshot)
        }
    }

    func setEnabled(_ enabled: Bool, item: StartupItem) {
        guard !isWorking else { return }
        let login = includesLoginApps
        let cron = includesSystemCron
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        queue.async {
            do {
                try self.service.setEnabled(enabled, item: item)
                let snapshot = self.service.scan(includeLoginApps: login, includeSystemCron: cron)
                self.publish(snapshot)
                DispatchQueue.main.async {
                    self.statusMessage = "\(item.name): \(enabled ? "enabled" : "disabled") for future launches."
                }
            } catch {
                self.logger.error("Startup change failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isWorking = false
                }
            }
        }
    }

    func openLoginSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
              NSWorkspace.shared.open(url) else {
            errorMessage = "Could not open Login Items. Open System Settings > General > Login Items manually."
            logger.error("Could not open macOS Login Items settings.")
            return
        }
    }

    private func publish(_ snapshot: StartupSnapshot) {
        for warning in snapshot.warnings { logger.warning("\(warning)") }
        DispatchQueue.main.async {
            self.items = snapshot.items
            self.warnings = snapshot.warnings
            self.isWorking = false
        }
    }
}

private enum StartupSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case kind = "Type"
    case state = "State"
    case scope = "Scope"
    var id: Self { self }
}

private struct StartupChange: Identifiable {
    let item: StartupItem
    let enabled: Bool
    var id: String { item.id }
}

struct StartupTab: View {
    @StateObject private var monitor = StartupMonitor()
    @State private var search = ""
    @State private var kind: StartupKind?
    @State private var state: StartupState?
    @State private var sort: StartupSort = .name
    @State private var ascending = true
    @State private var selected: StartupItem.ID?
    @State private var pending: StartupChange?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Startup", systemImage: "power")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if monitor.isWorking { ProgressView().controlSize(.small) }
                Button("Load login apps") { monitor.refresh(loadLoginApps: true) }
                    .help("Read legacy login apps and app-owned background items. macOS may request Automation access to System Events.")
                Button("Load system cron") { monitor.refresh(loadSystemCron: true) }
                    .help("Read root's crontab with macOS administrator approval")
                Button("Login Items settings") { monitor.openLoginSettings() }
                Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh startup entries")
            }
            .disabled(monitor.isWorking)

            HStack(spacing: 10) {
                TextField("Search app, service label, command, or path", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("Type", selection: $kind) {
                    Text("All types").tag(Optional<StartupKind>.none)
                    ForEach(StartupKind.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }.frame(width: 190)
                Picker("State", selection: $state) {
                    Text("All states").tag(Optional<StartupState>.none)
                    ForEach(StartupState.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }.frame(width: 150)
                Picker("Sort", selection: $sort) {
                    ForEach(StartupSort.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 130)
                SortDirectionButton(ascending: $ascending)
            }

            Text("Disable future launches without stopping running processes. Protected macOS services stay read-only. App-owned background items are changed in macOS Login Items settings.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if !monitor.includesLoginApps || !monitor.includesSystemCron {
                Text("Services and your cron jobs are loaded automatically. Load login apps or system cron explicitly to grant the required macOS access.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if let error = monitor.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
            }
            if let message = monitor.statusMessage {
                Text(message).foregroundColor(Theme.memory).font(.system(size: 12)).textSelection(.enabled)
            }
            if !monitor.warnings.isEmpty {
                DisclosureGroup("Some entries could not be read (\(monitor.warnings.count))") {
                    ScrollView {
                        Text(monitor.warnings.joined(separator: "\n"))
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }
            }
            Text("\(visible.count) entries")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)

            Table(visible, selection: $selected) {
                TableColumn("Name / schedule") { Text($0.name).help($0.name) }.width(min: 170, ideal: 220)
                TableColumn("Type") { Text($0.kind.rawValue) }.width(135)
                TableColumn("Scope") { Text($0.domain.label) }.width(90)
                TableColumn("State") { Text($0.state.rawValue) }.width(75)
                TableColumn("Command / app") { Text($0.command).help($0.command) }.width(min: 180, ideal: 320)
                TableColumn("Startup control") { item in
                    if case .managedBackgroundItem = item.source {
                        Button("macOS settings") { monitor.openLoginSettings() }
                    } else if let restriction = item.restriction {
                        Label("Read-only", systemImage: "lock")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .help(restriction)
                    } else {
                        Button(item.state == .enabled ? "Disable" : "Enable") {
                            pending = StartupChange(item: item, enabled: item.state != .enabled)
                        }
                        .disabled(monitor.isWorking || item.state == .unknown)
                        .accessibilityLabel("\(item.state == .enabled ? "Disable" : "Enable") \(item.name)")
                    }
                }.width(130)
            }
            .font(.system(size: 11))
            .scrollContentBackground(.hidden)
            .overlay {
                if visible.isEmpty && !monitor.isWorking {
                    Text("No matching startup entries").foregroundColor(.secondary)
                }
            }
            if let item = monitor.items.first(where: { $0.id == selected }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.origin)
                    Text(item.command)
                    if let restriction = item.restriction {
                        Text(restriction).foregroundColor(.orange)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(Theme.background)
        .onAppear { monitor.refresh() }
        .alert(item: $pending) { change in
            let title = change.enabled ? "Enable \(change.item.name)?" : "Disable \(change.item.name)?"
            let message = change.item.domain == .system
                ? "This changes system-wide startup and requests macOS administrator approval. Running services are not stopped. Cron edits keep a private backup."
                : "This changes future startup for your account. Running processes are not stopped. You can enable the entry again here."
            let action = { monitor.setEnabled(change.enabled, item: change.item) }
            return Alert(
                title: Text(title), message: Text(message),
                primaryButton: change.enabled ? .default(Text("Enable"), action: action) : .destructive(Text("Disable"), action: action),
                secondaryButton: .cancel()
            )
        }
    }

    private var visible: [StartupItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return monitor.items.filter {
            (kind == nil || $0.kind == kind) && (state == nil || $0.state == state)
                && (query.isEmpty || [$0.name, $0.command, $0.origin, $0.kind.rawValue, $0.domain.label]
                    .contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { left, right in
            let comparison: ComparisonResult
            switch sort {
            case .name: comparison = left.name.localizedStandardCompare(right.name)
            case .kind: comparison = left.kind.rawValue.compare(right.kind.rawValue)
            case .state: comparison = left.state.rawValue.compare(right.state.rawValue)
            case .scope: comparison = left.domain.label.compare(right.domain.label)
            }
            let order = comparison == .orderedSame ? left.id.compare(right.id) : comparison
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}
