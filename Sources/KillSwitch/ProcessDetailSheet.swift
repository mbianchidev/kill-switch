import SwiftUI
import SystemMetricsCore
import TableQueryCore

struct ProcessDetailSheet: View {
    let process: ActivityProcessDescriptor
    let resourceMonitor: ResourceMonitor
    @StateObject private var inspection: ProcessInspectionMonitor
    @State private var connectionsSelected = false
    @State private var fileSearch = ""
    @State private var connectionSearch = ""
    @State private var fileSorting = TableComparator(field: OpenFileTableFields.path)
    @State private var connectionSorting = TableComparator(field: ConnectionTableFields.local)
    @State private var selectedFile: OpenFileRecord.ID?
    @State private var selectedConnection: NetworkConnectionRecord.ID?

#if KILLSWITCH_PERFORMANCE_PROBE
    var performanceObserveBody: (() -> Void)?
    var performanceObserveCurrent: ((ResourceProcess?) -> Void)?
#endif

    init(process: ActivityProcessDescriptor, resourceMonitor: ResourceMonitor) {
        self.process = process
        self.resourceMonitor = resourceMonitor
        _inspection = StateObject(wrappedValue: ProcessInspectionMonitor(target: process.identity))
    }

    var body: some View {
#if KILLSWITCH_PERFORMANCE_PROBE
        performanceObserveBody?()
#endif
        return VStack(alignment: .leading, spacing: 14) {
            resourceHeader
            Divider()
            HStack {
                Picker("Inspect", selection: $connectionsSelected) {
                    Text("Open files").tag(false)
                    Text("Connections").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
                InspectionRefreshButton(monitor: inspection)
            }
            if connectionsSelected {
                let rows = TableQuery(search: connectionSearch, fields: ConnectionTableFields.all)
                    .apply(to: inspection.connections, sorting: connectionSorting, identity: \.id)
                TableSearchControls(search: $connectionSearch, fields: ConnectionTableFields.all, prompt: "Search this process's connections")
                TableSortControls(fields: ConnectionTableFields.all, sorting: $connectionSorting)
                InspectionStatus(monitor: inspection, count: rows.count, noun: "connections")
                ConnectionsTable(rows: rows, identities: inspection.identities, selection: $selectedConnection, sorting: $connectionSorting, compact: true)
            } else {
                let rows = TableQuery(search: fileSearch, fields: OpenFileTableFields.all)
                    .apply(to: inspection.files, sorting: fileSorting, identity: \.id)
                TableSearchControls(search: $fileSearch, fields: OpenFileTableFields.all, prompt: "Search this process's files, or size >= 1MB")
                TableSortControls(fields: OpenFileTableFields.columns, sorting: $fileSorting)
                InspectionStatus(monitor: inspection, count: rows.count, noun: "files")
                OpenFilesTable(rows: rows, identities: inspection.identities, selection: $selectedFile, sorting: $fileSorting, compact: true)
            }
            Text("Read-only inspection of this exact process lifetime. macOS permissions still apply. Open files are not necessarily locked; unreported locks and unavailable measurements are not zeroes. Inspection pauses when hidden.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(minWidth: 800, idealWidth: 1_000, minHeight: 540, idealHeight: 650)
        .background(Theme.background)
        .environment(\.inspectProcess, nil)
        .inspectionSampling(inspection, mode: .files)
    }

    private var resourceHeader: some View {
#if KILLSWITCH_PERFORMANCE_PROBE
        return ProcessDetailResourceHeader(
            process: process, resourceMonitor: resourceMonitor, performanceObserveCurrent: performanceObserveCurrent
        )
#else
        return ProcessDetailResourceHeader(process: process, resourceMonitor: resourceMonitor)
#endif
    }
}

private struct ProcessDetailResourceHeader: View {
    let process: ActivityProcessDescriptor
    @ObservedObject var resourceMonitor: ResourceMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigatePage) private var navigate
#if KILLSWITCH_PERFORMANCE_PROBE
    var performanceObserveCurrent: ((ResourceProcess?) -> Void)?
#endif

    var body: some View {
        let current = resourceMonitor.processes.first { $0.identity == process.identity }
#if KILLSWITCH_PERFORMANCE_PROBE
        performanceObserveCurrent?(current)
#endif
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(process.name, systemImage: "terminal")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("PID \(process.id.pid) / \(process.user)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Show resource history") {
                    resourceMonitor.focusedProcess = process.identity
                    navigate?(.dashboard)
                    dismiss()
                }
                .disabled(!resourceMonitor.historyProcesses.contains(where: { $0.id == process.id }))
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 24) {
                metric("CPU", current?.cpu.map { String(format: "%.1f%%", $0) } ?? "N/A")
                metric("Memory", current.map { formatBytes($0.memoryBytes) } ?? "N/A")
                metric("Threads", current?.threads.map(String.init) ?? "N/A")
                metric("CPU time", current.map { formatDuration($0.cpuTimeSeconds) } ?? "N/A")
                Spacer()
                if current == nil {
                    Text("Live resource reading unavailable")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .monospaced))
        }
        .accessibilityElement(children: .combine)
    }
}
