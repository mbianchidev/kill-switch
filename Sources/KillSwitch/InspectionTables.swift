import AppKit
import SwiftUI
import SystemMetricsCore
import TableQueryCore

struct OpenFilesTable: View {
    let rows: [OpenFileRecord]
    let identities: [Int32: ActivityProcessIdentity]
    @Binding var selection: OpenFileRecord.ID?
    @Binding var sorting: TableComparator<OpenFileRecord>
    var compact = false

    var body: some View {
        Group {
            if compact {
                Table(rows, selection: $selection, sortOrder: tableSortOrder($sorting)) {
                    pathColumn
                    detailColumns
                }
            } else {
                Table(rows, selection: $selection, sortOrder: tableSortOrder($sorting)) {
                    pathColumn
                    TableColumn("Process", sortUsing: TableComparator(field: OpenFileTableFields.process)) { Text($0.process) }
                        .width(min: 110, ideal: 150)
                    TableColumn("PID", sortUsing: TableComparator(field: OpenFileTableFields.pid)) { Text(String($0.pid)) }.width(55)
                    TableColumn("User", sortUsing: TableComparator(field: OpenFileTableFields.user)) { Text($0.user) }.width(95)
                    detailColumns
                    TableColumn("Inspect") { file in
                        InspectProcessButton(process: identities[file.pid].map {
                            ActivityProcessDescriptor(identity: $0, name: file.process, user: file.user)
                        })
                    }.width(65)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .scrollContentBackground(.hidden)
    }

    @TableColumnBuilder<OpenFileRecord, TableComparator<OpenFileRecord>>
    private var pathColumn: some TableColumnContent<OpenFileRecord, TableComparator<OpenFileRecord>> {
        TableColumn("Path", sortUsing: TableComparator(field: OpenFileTableFields.path)) { Text($0.path).help($0.path) }
            .width(min: 230, ideal: 360)
    }

    @TableColumnBuilder<OpenFileRecord, TableComparator<OpenFileRecord>>
    private var detailColumns: some TableColumnContent<OpenFileRecord, TableComparator<OpenFileRecord>> {
        TableColumn("FD", sortUsing: TableComparator(field: OpenFileTableFields.descriptor)) { Text($0.descriptor) }.width(45)
        TableColumn("Access", sortUsing: TableComparator(field: OpenFileTableFields.access)) { Text($0.accessDescription) }.width(85)
        TableColumn("Lock", sortUsing: TableComparator(field: OpenFileTableFields.lock)) { Text($0.lockDescription) }.width(110)
        TableColumn("Type", sortUsing: TableComparator(field: OpenFileTableFields.kind)) { Text($0.kind) }.width(55)
        TableColumn("Size", sortUsing: TableComparator(field: OpenFileTableFields.size)) { Text($0.size.map(formatBytes) ?? "N/A") }.width(90)
    }
}

struct ConnectionsTable: View {
    let rows: [NetworkConnectionRecord]
    let identities: [Int32: ActivityProcessIdentity]
    @Binding var selection: NetworkConnectionRecord.ID?
    @Binding var sorting: TableComparator<NetworkConnectionRecord>
    var compact = false

    var body: some View {
        Group {
            if compact {
                Table(rows, selection: $selection, sortOrder: tableSortOrder($sorting)) { connectionColumns }
            } else {
                Table(rows, selection: $selection, sortOrder: tableSortOrder($sorting)) {
                    TableColumn("Process", sortUsing: TableComparator(field: ConnectionTableFields.process)) { Text($0.process) }.width(min: 110, ideal: 140)
                    TableColumn("PID", sortUsing: TableComparator(field: ConnectionTableFields.pid)) { Text(String($0.pid)) }.width(55)
                    TableColumn("User", sortUsing: TableComparator(field: ConnectionTableFields.user)) { Text($0.user) }.width(90)
                    connectionColumns
                    TableColumn("Inspect") { connection in
                        InspectProcessButton(process: identities[connection.pid].map {
                            ActivityProcessDescriptor(identity: $0, name: connection.process, user: connection.user)
                        })
                    }.width(65)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .scrollContentBackground(.hidden)
    }

    @TableColumnBuilder<NetworkConnectionRecord, TableComparator<NetworkConnectionRecord>>
    private var connectionColumns: some TableColumnContent<NetworkConnectionRecord, TableComparator<NetworkConnectionRecord>> {
        TableColumn("Protocol", sortUsing: TableComparator(field: ConnectionTableFields.protocolDisplay)) { Text($0.protocolDescription) }.width(90)
        TableColumn("Local endpoint", sortUsing: TableComparator(field: ConnectionTableFields.local)) { Text($0.local).help($0.local) }.width(min: 150, ideal: 200)
        TableColumn("Remote endpoint", sortUsing: TableComparator(field: ConnectionTableFields.remote)) { Text($0.remote ?? "None").help($0.remote ?? "No remote endpoint") }
            .width(min: 150, ideal: 200)
        TableColumn("State", sortUsing: TableComparator(field: ConnectionTableFields.state)) { Text($0.state) }.width(125)
        TableColumn("HTTP") { OpenListenerButton(connection: $0) }.width(85)
    }
}

struct OpenListenerButton: View {
    let connection: NetworkConnectionRecord
    @State private var errorMessage: String?
    @Environment(\.allowsLiveOperations) private var allowsOperations

    var body: some View {
        Button("Open HTTP") {
            guard let url = connection.browserURL else {
                errorMessage = "This entry does not have a verified HTTP listener address."
                fputs("KillSwitch could not construct a local HTTP listener address.\n", stderr)
                return
            }
            if !NSWorkspace.shared.open(url) {
                let message = "macOS could not open \(url.absoluteString) in your browser."
                errorMessage = message
                fputs("KillSwitch: \(message)\n", stderr)
            }
        }
        .buttonStyle(.borderless)
        .disabled(connection.browserURL == nil || !allowsOperations)
        .help("Try this TCP listener as HTTP. Not every listener is a web server.")
        .accessibilityLabel("Open HTTP listener \(connection.local)")
        .alert("Could not open listener", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }
}

struct CopyInspectionTextButton: View {
    let title: String
    let value: String
    @State private var copied = false
    @State private var failed = false
    @Environment(\.allowsLiveOperations) private var allowsOperations

    var body: some View {
        Button(copied ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(value, forType: .string) {
                copied = true
            } else {
                failed = true
                fputs("KillSwitch could not copy inspection text to the clipboard.\n", stderr)
            }
        }
        .disabled(!allowsOperations)
        .onChange(of: value) { _ in copied = false }
        .alert("Could not copy text", isPresented: $failed) { Button("OK") {} } message: {
            Text("The clipboard did not accept the text. Try copying again.")
        }
        .accessibilityLabel(copied ? "\(title): copied" : title)
    }
}

struct InspectionRefreshButton: View {
    @ObservedObject var monitor: ProcessInspectionMonitor
    @Environment(\.isKillSwitchWindowVisible) private var visible
    @Environment(\.allowsLiveOperations) private var allowsOperations

    var body: some View {
        Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
            .disabled(monitor.isRefreshing || !visible || !allowsOperations)
            .help("Refresh now")
            .accessibilityLabel("Refresh process inspection")
    }
}

private struct InspectionSampling: ViewModifier {
    let monitor: ProcessInspectionMonitor
    let mode: ProcessInspectionMonitor.Mode
    @Environment(\.isKillSwitchWindowVisible) private var visible
    @Environment(\.allowsLiveOperations) private var allowsOperations

    func body(content: Content) -> some View {
        content
            .onAppear { update() }
            .onChange(of: visible) { _ in update() }
            .onChange(of: allowsOperations) { _ in update() }
            .onDisappear { monitor.stop() }
    }

    private func update() {
#if KILLSWITCH_PERFORMANCE_PROBE
        if !allowsOperations {
            monitor.restorePerformanceFixture()
            return
        }
#endif
        if visible && allowsOperations { monitor.start(mode) } else { monitor.stop() }
    }
}

extension View {
    func inspectionSampling(_ monitor: ProcessInspectionMonitor, mode: ProcessInspectionMonitor.Mode) -> some View {
        modifier(InspectionSampling(monitor: monitor, mode: mode))
    }
}
