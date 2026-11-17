import AppKit
import DiskCleanupCore
import SwiftUI
import TableQueryCore

struct FolderSizeWatchRowModel: Identifiable {
    let watch: FolderSizeWatch
    let status: FolderSizeWatchStatus

    var id: UUID { watch.id }
    var hasReachedLimit: Bool {
        if case .reached = watch.alertState { return true }
        return false
    }
    var usagePercent: Double? {
        status.measurement.map { Double($0.sizeBytes) / Double(watch.thresholdBytes) * 100 }
    }
}

private enum WatchTableFields {
    static let name = TableField<FolderSizeWatchRowModel>.text("name", title: "Folder") { $0.watch.name }
    static let path = TableField<FolderSizeWatchRowModel>.text("path", title: "Path") { $0.watch.path }
    static let size = TableField<FolderSizeWatchRowModel>.number("size", title: "Size", aliases: ["bytes"], unit: .bytes) {
        (row: FolderSizeWatchRowModel) -> Decimal? in row.status.measurement.map { Decimal($0.sizeBytes) }
    }
    static let limit = TableField<FolderSizeWatchRowModel>.number("limit", title: "Alert limit", aliases: ["threshold"], unit: .bytes) {
        (row: FolderSizeWatchRowModel) -> Decimal? in Decimal(row.watch.thresholdBytes)
    }
    static let usage = TableField<FolderSizeWatchRowModel>.number("usage", title: "Usage %", aliases: ["usage%"], unit: .percent) {
        (row: FolderSizeWatchRowModel) -> Double? in row.usagePercent
    }
    static let reached = TableField<FolderSizeWatchRowModel>.boolean("reached", title: "Limit reached") { $0.hasReachedLimit }
    static let monitoring = TableField<FolderSizeWatchRowModel>.boolean("monitoring", title: "Monitoring", aliases: ["enabled"]) {
        $0.watch.isEnabled
    }
    static let measured = TableField<FolderSizeWatchRowModel>.date("measured", title: "Last measured") {
        $0.status.measurement?.measuredAt
    }
    static let columns = [name, path, size, limit, usage, measured]
    static let all = columns + [reached, monitoring]
}

private enum AlertTableFields {
    static let date = TableField<FolderSizeAlert>.date("date", title: "Alert time", aliases: ["time"]) { $0.date }
    static let name = TableField<FolderSizeAlert>.text("name", title: "Folder") { $0.name }
    static let path = TableField<FolderSizeAlert>.text("path", title: "Path") { $0.path }
    static let size = TableField<FolderSizeAlert>.number("size", title: "Size", aliases: ["bytes"], unit: .bytes) {
        (alert: FolderSizeAlert) -> Decimal? in Decimal(alert.sizeBytes)
    }
    static let limit = TableField<FolderSizeAlert>.number("limit", title: "Alert limit", aliases: ["threshold"], unit: .bytes) {
        (alert: FolderSizeAlert) -> Decimal? in Decimal(alert.thresholdBytes)
    }
    static let complete = TableField<FolderSizeAlert>.boolean("complete", title: "Complete measurement") { $0.isMeasurementComplete }
    static let columns = [date, name, path, size, limit]
    static let all = columns + [complete]
}

struct FolderSizeAlertsTab: View {
    @ObservedObject var monitor: FolderSizeMonitor
    @Environment(\.isKillSwitchWindowVisible) private var windowVisible
    @Environment(\.isKillSwitchPageVisible) private var pageVisible
    @State private var watchSearch = ""
    @State private var watchSorting = TableComparator(field: WatchTableFields.usage, order: .reverse)
    @State private var alertSearch = ""
    @State private var alertSorting = TableComparator(field: AlertTableFields.date, order: .reverse)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsCard
                    notices
                    watchesSection
                    alertsSection
                }
                .padding(16)
            }
        }
        .background(Theme.background)
        .onAppear {
            if shouldAcknowledge { monitor.acknowledgeAlerts() }
        }
        .onChange(of: shouldAcknowledge) { acknowledge in
            if acknowledge { monitor.acknowledgeAlerts() }
        }
    }

    /// Alerts count as seen only while this page is shown in a visible window.
    private var shouldAcknowledge: Bool {
        windowVisible && pageVisible && !monitor.unacknowledgedAlerts.isEmpty
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: MainTab.folderAlerts.icon)
                .foregroundColor(Theme.diskOccupied)
            VStack(alignment: .leading, spacing: 2) {
                Text("Folder size alerts")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("Get an alert in KillSwitch and from macOS when a folder reaches its size limit.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer()
            Button(action: chooseFolders) {
                Label("Add folder…", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.white.opacity(0.8))
            .help("Choose one or more folders to watch")
            Button { monitor.checkNow() } label: {
                Label("Check now", systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.white.opacity(0.8))
            .disabled(!monitor.watches.contains(where: \.isEnabled))
            .help("Measure every monitored folder now")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Check every")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.85))
                Picker("Check every", selection: $monitor.intervalSeconds) {
                    ForEach(FolderSizeMonitor.intervalOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 90)
                Spacer()
                if monitor.isMeasuring {
                    ProgressView()
                        .controlSize(.small)
                    Text("Measuring…")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                } else if let last = monitor.lastMeasured {
                    Text("Last measured: \(last.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            Text("Monitored folders are measured when KillSwitch starts, when added or changed, and at this interval, including while the window is hidden. A folder alerts once when it reaches its limit and can alert again after a complete measurement falls below 95% of that limit.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.2)))
    }

    @ViewBuilder
    private var notices: some View {
        if let error = monitor.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { monitor.clearError() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.6))
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss error")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
        if monitor.permissionDeniedCount > 0 {
            HStack(spacing: 10) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .foregroundColor(.orange)
                Text("\(monitor.permissionDeniedCount) protected location(s) could not be measured, so some sizes are lower bounds.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Button("Full Disk Access settings") { monitor.openFullDiskAccess() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
        }
    }

    private var watchesSection: some View {
        let models = monitor.watches.map {
            FolderSizeWatchRowModel(watch: $0, status: monitor.statuses[$0.id] ?? FolderSizeWatchStatus())
        }
        let rows = TableQuery(search: watchSearch, fields: WatchTableFields.all)
            .apply(to: models, sorting: watchSorting, identity: { $0.id.uuidString })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Watched folders (\(rows.count) of \(models.count))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                TableSortControls(fields: WatchTableFields.columns, sorting: $watchSorting)
            }
            TableSearchControls(search: $watchSearch, fields: WatchTableFields.all, prompt: "Search folders, or usage% >= 90")
            if rows.isEmpty {
                if models.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No folders are watched yet. Add a folder and choose the size that should trigger an alert.")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                        Button(action: chooseFolders) {
                            Label("Add folder…", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("No matching folders. Change or reset the filters.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
            } else {
                ForEach(rows) { row in
                    FolderSizeWatchRow(row: row, monitor: monitor)
                }
            }
        }
    }

    private var alertsSection: some View {
        let rows = TableQuery(search: alertSearch, fields: AlertTableFields.all)
            .apply(to: monitor.alerts, sorting: alertSorting, identity: { $0.id.uuidString })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent alerts (\(rows.count) of \(monitor.alerts.count))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                TableSortControls(fields: AlertTableFields.columns, sorting: $alertSorting)
            }
            TableSearchControls(search: $alertSearch, fields: AlertTableFields.all, prompt: "Search alerts, or size > 10GB")
            if rows.isEmpty {
                Text(monitor.alerts.isEmpty ? "No alerts this session." : "No matching alerts. Change or reset the filters.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ForEach(rows) { alert in
                    HStack(spacing: 12) {
                        Text(alert.date.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 84, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(abbreviatedPath(alert.path))
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(alert.isMeasurementComplete ? "" : "≥ ")\(formatBytes(alert.sizeBytes)) of \(formatBytes(alert.thresholdBytes))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.red.opacity(0.9))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Watch"
        panel.message = "Choose folders to watch. Each starts with a \(formatBytes(FolderSizeThreshold.defaultBytes)) alert limit that you can change."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        monitor.addFolders(panel.urls)
    }
}

private func abbreviatedPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

private struct FolderSizeWatchRow: View {
    let row: FolderSizeWatchRowModel
    let monitor: FolderSizeMonitor
    @State private var draftValue: String
    @State private var draftUnit: FolderSizeUnit
    @State private var draftError: String?

    init(row: FolderSizeWatchRowModel, monitor: FolderSizeMonitor) {
        self.row = row
        self.monitor = monitor
        let saved = FolderSizeThreshold.components(for: row.watch.thresholdBytes)
        _draftValue = State(initialValue: saved.value)
        _draftUnit = State(initialValue: saved.unit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundColor(Theme.diskOccupied)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.watch.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(abbreviatedPath(row.watch.path))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.watch.path)
                }
                Spacer(minLength: 8)
                statusBadge
                Toggle("Monitor", isOn: Binding(
                    get: { row.watch.isEnabled },
                    set: { monitor.setEnabled($0, for: row.id) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(row.watch.isEnabled ? "Pause monitoring this folder" : "Resume monitoring this folder")
                .accessibilityLabel("Monitor \(row.watch.name)")
                Button { monitor.revealInFinder(row.watch) } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(row.watch.name) in Finder")
                Button { monitor.remove(row.id) } label: {
                    Image(systemName: "minus.circle")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Stop watching this folder; its files are not changed")
                .accessibilityLabel("Stop watching \(row.watch.name)")
            }
            HStack(spacing: 12) {
                usage
                Spacer(minLength: 8)
                thresholdEditor
            }
            detail
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(row.hasReachedLimit ? Color.red.opacity(0.12) : Color.white.opacity(0.05))
        )
        .onChange(of: row.watch.thresholdBytes) { bytes in
            let saved = FolderSizeThreshold.components(for: bytes)
            draftValue = saved.value
            draftUnit = saved.unit
            draftError = nil
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !row.watch.isEnabled {
            badge("Paused", systemImage: "pause.circle", color: .white.opacity(0.5))
        } else if row.status.isMeasuring {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Measuring…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
        } else if row.status.errorMessage != nil, row.status.measurement == nil {
            badge("Unavailable", systemImage: "xmark.octagon.fill", color: .red)
        } else if row.hasReachedLimit {
            badge("Limit reached", systemImage: "exclamationmark.triangle.fill", color: .red)
        } else if row.status.measurement != nil {
            badge("Below limit", systemImage: "checkmark.circle.fill", color: .green)
        } else {
            badge("Waiting", systemImage: "clock", color: .white.opacity(0.5))
        }
    }

    private func badge(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
    }

    private var usage: some View {
        let fraction = min(1, max(0, (row.usagePercent ?? 0) / 100))
        let reached = row.hasReachedLimit
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(reached ? Color.red : (fraction >= 0.9 ? Color.orange : Theme.diskCleanupBar))
                    .frame(width: 220 * fraction)
            }
            .frame(width: 220, height: 6)
            .accessibilityHidden(true)
            Text(usageText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(reached ? .red.opacity(0.9) : .white.opacity(0.7))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Size of \(row.watch.name)")
        .accessibilityValue(usageText)
    }

    private var usageText: String {
        guard let measurement = row.status.measurement else {
            return "Not measured yet · limit \(formatBytes(row.watch.thresholdBytes))"
        }
        let prefix = measurement.isComplete ? "" : "≥ "
        let percent = row.usagePercent.map { String(format: "%.0f%%", $0) } ?? "—"
        return "\(prefix)\(formatBytes(measurement.sizeBytes)) of \(formatBytes(row.watch.thresholdBytes)) (\(percent))"
    }

    private var thresholdEditor: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Text("Alert at")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                TextField("Limit", text: $draftValue)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .onSubmit(saveThreshold)
                    .accessibilityLabel("Alert limit for \(row.watch.name)")
                Picker("Unit", selection: $draftUnit) {
                    ForEach(FolderSizeUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 66)
                .accessibilityLabel("Alert limit unit for \(row.watch.name)")
                Button("Save", action: saveThreshold)
                    .controlSize(.small)
                    .disabled(!hasUnsavedThreshold)
                    .help("Save the alert limit and measure this folder again")
            }
            if let draftError {
                Text(draftError)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
        }
    }

    private var hasUnsavedThreshold: Bool {
        let saved = FolderSizeThreshold.components(for: row.watch.thresholdBytes)
        return draftValue.trimmingCharacters(in: .whitespacesAndNewlines) != saved.value || draftUnit != saved.unit
    }

    @ViewBuilder
    private var detail: some View {
        if let error = row.status.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .textSelection(.enabled)
        } else if let measurement = row.status.measurement, !measurement.isComplete {
            Label(
                "\(measurement.permissionDeniedCount + measurement.unreadableItemCount) item(s) could not be read; the size is a lower bound.",
                systemImage: "lock.trianglebadge.exclamationmark"
            )
            .font(.system(size: 11))
            .foregroundColor(.orange)
        }
    }

    private func saveThreshold() {
        do {
            let bytes = try FolderSizeThreshold.bytes(from: draftValue, unit: draftUnit)
            draftError = nil
            monitor.setThreshold(bytes, for: row.id)
        } catch {
            draftError = error.localizedDescription
        }
    }
}

/// Shows unacknowledged folder size alerts above every page until reviewed or dismissed.
struct FolderSizeAlertBanner: View {
    @ObservedObject var monitor: FolderSizeMonitor
    let review: () -> Void

    var body: some View {
        if let alert = monitor.unacknowledgedAlerts.first {
            let others = monitor.unacknowledgedAlerts.count - 1
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .accessibilityHidden(true)
                Text("Folder size alert: \(alert.name) reached \(formatBytes(alert.thresholdBytes))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(others > 0 ? "(+\(others) more)" : "(\(alert.isMeasurementComplete ? "" : "at least ")\(formatBytes(alert.sizeBytes)) now)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer()
                Button("Review") {
                    monitor.acknowledgeAlerts()
                    review()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button { monitor.acknowledgeAlerts() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.6))
                .help("Dismiss")
                .accessibilityLabel("Dismiss folder size alerts")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.18))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Folder size alert")
        }
    }
}
