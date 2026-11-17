import Charts
import SwiftUI
import SystemMetricsCore
import TableQueryCore

struct ResourcesTab: View {
    @ObservedObject var monitor: ResourceMonitor
    private let metric: ResourceMetric
    @State private var sorting = TableComparator(field: ResourceTableFields.cpu, order: .reverse)
    @State private var searchText = ""
    @State private var samplingID = UUID()
    @Environment(\.navigatePage) private var navigate
    @Environment(\.isKillSwitchPageVisible) private var pageVisible
    @State private var historySearch = ""
    @State private var columnWidths = ResourceColumnWidths()

    init(monitor: ResourceMonitor, initialMetric: ResourceMetric = .cpu) {
        self.monitor = monitor
        metric = initialMetric
        _sorting = State(initialValue: TableComparator(
            field: ResourceTableFields.defaultField(for: initialMetric), order: .reverse
        ))
    }

    var body: some View {
        Group {
            if pageVisible { pageContent }
        }
    }

    private var pageContent: some View {
        let rows = visibleProcesses
        return GeometryReader { geometry in
            VStack(spacing: 0) {
                header(count: rows.count)
                Divider()
                processTable(rows)
                Divider()
                if metric != .energy {
                    ActivityHistoryControls(monitor: monitor, processSearch: $historySearch)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                }
                instrumentRail(compact: geometry.size.width < 900)
            }
        }
        .background(Theme.background)
        .onAppear { monitor.setMetric(metric, owner: samplingID) }
        .onDisappear { monitor.setMetric(nil, owner: samplingID) }
    }

    private func header(count: Int) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Label("\(metric.rawValue) resources", systemImage: "waveform.path.ecg")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                ProcessScopePicker(monitor: monitor)
            }

            if metric == .network {
                HStack(spacing: 12) {
                    Button("Inspect connections") { navigate?(.connections) }
                        .disabled(navigate == nil)
                    Text("Traffic and connections share the same process ownership scope.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            Group {
                TableSearchControls(
                    search: $searchText, fields: ResourceTableFields.all, prompt: "Search processes, or CPU% > 40",
                    resetAdditional: { monitor.showAllUsers = false }
                )
                HStack(spacing: 10) {
                    TableSortControls(fields: ResourceTableFields.columns(for: metric), sorting: $sorting)

                    Button {
                        monitor.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh now")

                    Text("\(count) processes")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))

                    Spacer()

                    if let lastUpdated = monitor.lastUpdated {
                        Text("Updated \(lastUpdated.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                    } else {
                        Text("Collecting system metrics…")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }

            ActivityMonitorErrors(monitor: monitor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    private func processTable(_ rows: [ResourceProcess]) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.element.pid) { index, process in
                        ResourceProcessRow(
                            process: process,
                            metric: metric,
                            isSelected: process.identity != nil && monitor.focusedProcess == process.identity,
                            isAlternate: index.isMultiple(of: 2) == false,
                            widths: columnWidths,
                            onSelect: {
                                if let identity = process.identity { monitor.focusedProcess = identity }
                            },
                            onKill: { monitor.kill(pid: process.pid) }
                        )
                    }
                } header: {
                    ResourceTableHeader(metric: metric, sorting: $sorting, widths: $columnWidths)
                }
            }
            .frame(minWidth: tableWidth, alignment: .leading)
        }
        .background(Color.black.opacity(0.08))
    }

    private func instrumentRail(compact: Bool) -> some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            VStack(alignment: .leading, spacing: 8) {
                Text(chartTitle)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(.white.opacity(0.5))

                Group {
                    if metric == .energy {
                        ResourceHistoryChart(
                            metric: metric, history: monitor.history[metric] ?? [],
                            pressure: monitor.memory.pressurePercent
                        )
                    } else {
                        ActivityTimelineChart(
                            metric: metric, history: monitor.timeline, range: monitor.historyRange,
                            now: monitor.lastUpdated ?? Date(), isProcess: monitor.focusedProcess != nil
                        )
                    }
                }
                .frame(minWidth: 300, idealWidth: 390, maxWidth: compact ? .infinity : 440, minHeight: 132, maxHeight: 132)
            }

            if !compact { Divider().frame(height: 150) }

            VStack(alignment: .leading, spacing: 6) {
                Text("ENTIRE MAC · NOW")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                summaryValues
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    @ViewBuilder
    private var summaryValues: some View {
        switch metric {
        case .cpu:
            FlowLayout(spacing: 10) {
                ResourceValue(label: "System", value: monitor.cpu.isAvailable ? percent(monitor.cpu.systemPercent) : "N/A", color: Theme.cpuSystem)
                ResourceValue(label: "User", value: monitor.cpu.isAvailable ? percent(monitor.cpu.userPercent) : "N/A", color: Theme.cpuUser)
                ResourceValue(label: "Idle", value: monitor.cpu.isAvailable ? percent(monitor.cpu.idlePercent) : "N/A")
                ResourceValue(label: "Threads", value: "\(monitor.cpu.threadCount)")
                ResourceValue(label: "Processes", value: "\(monitor.cpu.processCount)")
                ResourceValue(label: "Running", value: "\(monitor.cpu.runningCount)")
            }
        case .memory:
            FlowLayout(spacing: 10) {
                ResourceValue(
                    label: "Memory pressure",
                    value: monitor.memory.pressurePercent.map { percent($0) } ?? "—",
                    color: memoryPressureColor
                )
                ResourceValue(label: "Physical memory", value: formatBytes(monitor.memory.physicalBytes))
                ResourceValue(label: "Memory used", value: formatBytes(monitor.memory.usedBytes))
                ResourceValue(label: "App memory", value: formatBytes(monitor.memory.appBytes))
                ResourceValue(label: "Cached files", value: formatBytes(monitor.memory.cachedBytes))
                ResourceValue(label: "Wired memory", value: formatBytes(monitor.memory.wiredBytes))
                ResourceValue(label: "Compressed", value: formatBytes(monitor.memory.compressedBytes))
                ResourceValue(label: "Swap used", value: formatBytes(monitor.memory.swapUsedBytes))
            }
        case .energy:
            FlowLayout(spacing: 10) {
                ResourceValue(
                    label: "Reported energy impact",
                    value: ProcessEnergyCache.totalPower(monitor.processes.map(\.power)).map { String(format: "%.1f", $0) } ?? "N/A",
                    color: Theme.energy
                )
                ResourceValue(
                    label: "Remaining charge",
                    value: monitor.battery.chargePercent.map { "\($0)%" } ?? "—"
                )
                ResourceValue(label: "Power source", value: monitor.battery.source)
                ResourceValue(label: "Battery", value: monitor.battery.status.capitalized)
                if let time = monitor.battery.timeRemaining {
                    ResourceValue(label: "Time remaining", value: time)
                }
            }
        case .disk:
            VStack(alignment: .leading, spacing: 8) {
                DiskCapacityBreakdown(capacity: monitor.disk.capacity)

                FlowLayout(spacing: 10) {
                    ResourceValue(label: "Reads in", value: monitor.disk.isAvailable ? formatNumber(monitor.disk.reads) : "N/A")
                    ResourceValue(label: "Data read", value: monitor.disk.isAvailable ? formatBytes(monitor.disk.readBytes) : "N/A", color: Theme.inbound)
                    ResourceValue(label: "Writes out", value: monitor.disk.isAvailable ? formatNumber(monitor.disk.writes) : "N/A")
                    ResourceValue(label: "Data written", value: monitor.disk.isAvailable ? formatBytes(monitor.disk.writtenBytes) : "N/A", color: Theme.outbound)
                    ResourceValue(label: "Reads in/sec", value: formatRate(monitor.disk.readsPerSecond))
                    ResourceValue(label: "Data read/sec", value: formatByteRate(monitor.disk.readBytesPerSecond))
                    ResourceValue(label: "Writes out/sec", value: formatRate(monitor.disk.writesPerSecond))
                    ResourceValue(label: "Data written/sec", value: formatByteRate(monitor.disk.writtenBytesPerSecond))
                }
            }
        case .network:
            FlowLayout(spacing: 10) {
                ResourceValue(label: "Packets in", value: monitor.network.isAvailable ? formatNumber(monitor.network.receivedPackets) : "N/A")
                ResourceValue(label: "Data received", value: monitor.network.isAvailable ? formatBytes(monitor.network.receivedBytes) : "N/A", color: Theme.inbound)
                ResourceValue(label: "Packets out", value: monitor.network.isAvailable ? formatNumber(monitor.network.sentPackets) : "N/A")
                ResourceValue(label: "Data sent", value: monitor.network.isAvailable ? formatBytes(monitor.network.sentBytes) : "N/A", color: Theme.outbound)
                ResourceValue(label: "Packets in/sec", value: formatRate(monitor.network.receivedPacketsPerSecond))
                ResourceValue(label: "Data received/sec", value: formatByteRate(monitor.network.receivedBytesPerSecond))
                ResourceValue(label: "Packets out/sec", value: formatRate(monitor.network.sentPacketsPerSecond))
                ResourceValue(label: "Data sent/sec", value: formatByteRate(monitor.network.sentBytesPerSecond))
            }
        }
    }

    private var visibleProcesses: [ResourceProcess] {
        let scoped = monitor.processes.filter {
            monitor.showAllUsers || $0.user == monitor.currentUsername
        }

        return TableQuery(search: searchText, fields: ResourceTableFields.all)
            .apply(to: scoped, sorting: sorting, identity: { String($0.pid) })
    }

    private var chartTitle: String {
        if metric == .energy { return "ENERGY IMPACT · LAST 5 MINUTES" }
        return "\(metric.rawValue.uppercased()) · \(monitor.historyRange.rawValue.uppercased())"
    }

    private var tableWidth: CGFloat { columnWidths.tableWidth(for: metric) }

    private var memoryPressureColor: Color {
        guard let pressure = monitor.memory.pressurePercent else { return .secondary }
        if pressure >= 90 { return .red }
        if pressure >= 75 { return .yellow }
        return Theme.memory
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

/// Column widths for the custom process table. Header handles resize them and rows follow;
/// widths are kept per page while the app runs.
struct ResourceColumnWidths: Equatable {
    static let minimum: CGFloat = 40
    static let maximum: CGFloat = 640
    /// Horizontal padding around each metric cell, matching `ResourceTableCell`.
    static let cellPadding: CGFloat = 12
    static let actionsWidth: CGFloat = 84
    private static let defaults: [String: CGFloat] = [
        "name": 250, "cpu": 72, "cpuTime": 98, "threads": 74, "wakeups": 104, "kind": 72,
        "memory": 100, "openFiles": 86, "energy": 110, "power12h": 100, "appNap": 82, "preventsSleep": 120,
        "written": 118, "read": 118, "sent": 110, "received": 110, "sentPackets": 110, "receivedPackets": 110,
        "pid": 72, "user": 140
    ]
    private var custom: [String: CGFloat] = [:]

    subscript(field: TableField<ResourceProcess>) -> CGFloat {
        custom[field.id] ?? Self.defaults[field.id] ?? 100
    }

    mutating func set(_ field: TableField<ResourceProcess>, to width: CGFloat) {
        custom[field.id] = min(max(width.rounded(), Self.minimum), Self.maximum)
    }

    mutating func reset(_ field: TableField<ResourceProcess>) { custom[field.id] = nil }

    func tableWidth(for metric: ResourceMetric) -> CGFloat {
        ResourceTableFields.columns(for: metric).reduce(Self.actionsWidth) { total, field in
            total + self[field] + (field.id == ResourceTableFields.name.id ? 0 : Self.cellPadding)
        }
    }
}

/// A drag handle on a header cell's trailing edge. Double-click restores the default width;
/// VoiceOver adjusts it in 10-point steps.
private struct ColumnResizeHandle: View {
    let field: TableField<ResourceProcess>
    @Binding var widths: ResourceColumnWidths
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 16)
            .frame(width: 7, height: 30)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = startWidth ?? widths[field]
                        startWidth = start
                        widths.set(field, to: start + value.translation.width)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onTapGesture(count: 2) { widths.reset(field) }
            .help("Drag to resize \(field.title); double-click to restore its width")
            .accessibilityElement()
            .accessibilityLabel("Resize \(field.title) column")
            .accessibilityValue("\(Int(widths[field])) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: widths.set(field, to: widths[field] + 10)
                case .decrement: widths.set(field, to: widths[field] - 10)
                @unknown default: break
                }
            }
    }
}

private struct ResourceTableHeader: View {
    let metric: ResourceMetric
    @Binding var sorting: TableComparator<ResourceProcess>
    @Binding var widths: ResourceColumnWidths

    var body: some View {
        HStack(spacing: 0) {
            TableSortHeader(field: ResourceTableFields.name, sorting: $sorting)
                .padding(.horizontal, 10)
                .frame(width: widths[ResourceTableFields.name])
                .overlay(alignment: .trailing) { ColumnResizeHandle(field: ResourceTableFields.name, widths: $widths) }
            ForEach(ResourceTableFields.columns(for: metric).dropFirst(), id: \.id) { field in
                TableSortHeader(
                    field: field, sorting: $sorting,
                    alignment: field.id == ResourceTableFields.user.id ? .leading : .trailing
                )
                .frame(width: widths[field])
                .padding(.horizontal, ResourceColumnWidths.cellPadding / 2)
                .overlay(alignment: .trailing) { ColumnResizeHandle(field: field, widths: $widths) }
            }
            Text("Inspect / Kill").frame(width: ResourceColumnWidths.actionsWidth)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundColor(.white.opacity(0.52))
        .frame(height: 30)
        .background(Color(red: 0.105, green: 0.075, blue: 0.16))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ResourceProcessRow: View {
    let process: ResourceProcess
    let metric: ResourceMetric
    let isSelected: Bool
    let isAlternate: Bool
    let widths: ResourceColumnWidths
    let onSelect: () -> Void
    let onKill: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) { processName }
                .buttonStyle(.borderless)
                .disabled(process.identity == nil)
                .accessibilityLabel("Show history for \(process.name), PID \(pidString(process.pid))")
            switch metric {
            case .cpu:
                value(
                    process.cpu.map { String(format: "%.1f", $0) } ?? "N/A", width: widths[ResourceTableFields.cpu], color: Theme.cpuUser,
                    help: process.cpu == nil ? "CPU rates need two readable lifetime-matched samples." : nil
                )
                value(formatDuration(process.cpuTimeSeconds), width: widths[ResourceTableFields.cpuTime])
                value(
                    process.threads.map(String.init) ?? "—",
                    width: widths[ResourceTableFields.threads],
                    help: unavailableHelp(process.threads)
                )
                value(process.idleWakeUps.map(formatNumber) ?? "—", width: widths[ResourceTableFields.wakeups])
                value(process.kind ?? "—", width: widths[ResourceTableFields.kind], help: unavailableHelp(process.kind))
                value(pidString(process.pid), width: widths[ResourceTableFields.pid]).copyPID(process.pid)
                value(process.user, width: widths[ResourceTableFields.user], alignment: .leading)
            case .memory:
                value(formatBytes(process.memoryBytes), width: widths[ResourceTableFields.memory], color: Theme.memory)
                value(
                    process.threads.map(String.init) ?? "—",
                    width: widths[ResourceTableFields.threads],
                    help: unavailableHelp(process.threads)
                )
                value(
                    process.openFileCount.map(String.init) ?? "—",
                    width: widths[ResourceTableFields.openFiles],
                    help: unavailableHelp(process.openFileCount)
                )
                value(pidString(process.pid), width: widths[ResourceTableFields.pid]).copyPID(process.pid)
                value(process.user, width: widths[ResourceTableFields.user], alignment: .leading)
            case .energy:
                value(process.power.map { String(format: "%.1f", $0) } ?? "N/A", width: widths[ResourceTableFields.energy], color: Theme.energy)
                value(
                    process.power12Hour.map { String(format: "%.2f", $0) } ?? "—",
                    width: widths[ResourceTableFields.power12Hour]
                )
                value(boolean(process.appNap), width: widths[ResourceTableFields.appNap], help: appNapHelp)
                value(
                    boolean(process.preventsSleep), width: widths[ResourceTableFields.preventsSleep],
                    help: process.preventsSleep == nil ? "Sleep assertion state has not been read successfully for this process." : nil
                )
                value(pidString(process.pid), width: widths[ResourceTableFields.pid]).copyPID(process.pid)
                value(process.user, width: widths[ResourceTableFields.user], alignment: .leading)
            case .disk:
                value(
                    process.diskWrittenBytes.map(formatBytes) ?? "—",
                    width: widths[ResourceTableFields.diskWritten],
                    color: Theme.outbound,
                    help: unavailableHelp(process.diskWrittenBytes)
                )
                value(
                    process.diskReadBytes.map(formatBytes) ?? "—",
                    width: widths[ResourceTableFields.diskRead],
                    color: Theme.inbound,
                    help: unavailableHelp(process.diskReadBytes)
                )
                value(pidString(process.pid), width: widths[ResourceTableFields.pid]).copyPID(process.pid)
                value(process.user, width: widths[ResourceTableFields.user], alignment: .leading)
            case .network:
                value(process.sentBytes.map(formatBytes) ?? "N/A", width: widths[ResourceTableFields.networkSent], color: Theme.outbound)
                value(process.receivedBytes.map(formatBytes) ?? "N/A", width: widths[ResourceTableFields.networkReceived], color: Theme.inbound)
                value(process.sentPackets.map(formatNumber) ?? "N/A", width: widths[ResourceTableFields.sentPackets])
                value(process.receivedPackets.map(formatNumber) ?? "N/A", width: widths[ResourceTableFields.receivedPackets])
                value(pidString(process.pid), width: widths[ResourceTableFields.pid]).copyPID(process.pid)
                value(process.user, width: widths[ResourceTableFields.user], alignment: .leading)
            }

            InspectProcessButton(process: process.identity.map {
                ActivityProcessDescriptor(identity: $0, name: process.name, user: process.user)
            })
            .frame(width: 42)
            KillButton(pid: process.pid, action: onKill)
                .frame(width: 42)
        }
        .frame(height: 34)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var processName: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = process.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(.white.opacity(0.35))
                }
            }
            .frame(width: 18, height: 18)

            Text(process.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                .copyProcessName(process.name)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .frame(width: widths[ResourceTableFields.name], alignment: .leading)
    }

    private var rowBackground: Color {
        if isSelected { return Color.white.opacity(0.11) }
        return isAlternate ? Color.white.opacity(0.025) : .clear
    }

    private var appNapHelp: String {
        "macOS does not expose Activity Monitor's per-process App Nap state through a supported public interface."
    }

    private func unavailableHelp<T>(_ value: T?) -> String? {
        value == nil
            ? "macOS restricts this value for some processes, especially processes owned by another user."
            : nil
    }

    private func boolean(_ value: Bool?) -> String {
        guard let value else { return "—" }
        return value ? "Yes" : "No"
    }

    private func value(
        _ text: String,
        width: CGFloat,
        alignment: Alignment = .trailing,
        color: Color = .white.opacity(0.68),
        help: String? = nil
    ) -> some View {
        ResourceTableCell(text, width: width, alignment: alignment, color: color, help: help)
    }
}

private struct ResourceTableCell: View {
    let text: String
    let width: CGFloat
    let alignment: Alignment
    let color: Color
    let helpText: String?

    init(
        _ text: String,
        width: CGFloat,
        alignment: Alignment = .trailing,
        color: Color = .white.opacity(0.68),
        help: String? = nil
    ) {
        self.text = text
        self.width = width
        self.alignment = alignment
        self.color = color
        self.helpText = help
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(color)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 6)
            .help(helpText ?? "")
    }
}

private struct ResourceHistoryChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let metric: ResourceMetric
    let history: [ResourceHistoryPoint]
    let pressure: Double?

    var body: some View {
        let scale = chartScale
        let domain = timeDomain

        return VStack(alignment: .leading, spacing: 6) {
            Group {
                if isStartingUp {
                    startupChart
                } else {
                    chart
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...scale.maximum)
            .chartXAxis {
                AxisMarks(values: [domain.lowerBound, domain.upperBound]) { value in
                    AxisValueLabel(anchor: value.index == 0 ? .topLeading : .topTrailing) {
                        Text(value.index == 0 ? "5m ago" : "Now")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: scale.ticks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.white.opacity(0.12))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(scale.label(for: number))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.6))
                                .fixedSize()
                        }
                    }
                }
            }
            .chartPlotStyle { plotArea in
                plotArea
                    .background(accentColor.opacity(0.025))
                    .clipped()
            }
            .accessibilityLabel("\(metric.rawValue) history over the last five minutes")
            .overlay {
                if isStartingUp {
                    startupStatus
                        .transition(.opacity)
                }
            }

            HStack(spacing: 12) {
                legend
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: isStartingUp)
    }

    @ViewBuilder
    private var chart: some View {
        switch metric {
        case .cpu:
            Chart(history) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("Start", 0),
                    yEnd: .value("System CPU (%)", point.primary),
                    series: .value("CPU series", "System")
                )
                .foregroundStyle(Theme.cpuSystem.opacity(0.45))
                .interpolationMethod(.linear)

                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("System", point.primary),
                    yEnd: .value("Total CPU (%)", point.primary + (point.secondary ?? 0)),
                    series: .value("CPU series", "User")
                )
                .foregroundStyle(Theme.cpuUser.opacity(0.4))
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("System CPU (%)", point.primary),
                    series: .value("CPU boundary", "System")
                )
                .foregroundStyle(Theme.cpuSystem)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Total CPU (%)", point.primary + (point.secondary ?? 0)),
                    series: .value("CPU boundary", "Total")
                )
                .foregroundStyle(Theme.cpuUser)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.linear)
            }
        case .memory:
            Chart(history) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Pressure (%)", point.primary)
                )
                .foregroundStyle(memoryColor.opacity(0.3))
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Pressure (%)", point.primary)
                )
                .foregroundStyle(memoryColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.linear)
            }
        case .energy:
            Chart(history) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Energy impact (pts)", point.primary)
                )
                .foregroundStyle(Theme.energy.opacity(0.25))
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Energy impact (pts)", point.primary)
                )
                .foregroundStyle(Theme.energy)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.linear)
            }
        case .disk:
            Chart(history) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Read (bytes/s)", point.primary),
                    series: .value("Disk series", "Read")
                )
                .foregroundStyle(Theme.inbound)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Write (bytes/s)", point.secondary ?? 0),
                    series: .value("Disk series", "Write")
                )
                .foregroundStyle(Theme.outbound)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .interpolationMethod(.linear)
            }
        case .network:
            Chart(history) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Received (bytes/s)", point.primary),
                    series: .value("Network series", "Received")
                )
                .foregroundStyle(Theme.inbound)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Sent (bytes/s)", point.secondary ?? 0),
                    series: .value("Network series", "Sent")
                )
                .foregroundStyle(Theme.outbound)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .interpolationMethod(.linear)
            }
        }
    }

    private var startupChart: some View {
        Chart {
            if let point = history.last {
                RuleMark(x: .value("Latest sample", point.date))
                    .foregroundStyle(accentColor.opacity(0.28))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

                switch metric {
                case .cpu:
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("System CPU (%)", point.primary)
                    )
                    .foregroundStyle(Theme.cpuSystem)
                    .symbolSize(34)

                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Total CPU (%)", point.primary + (point.secondary ?? 0))
                    )
                    .foregroundStyle(Theme.cpuUser)
                    .symbolSize(34)
                case .memory:
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Pressure (%)", point.primary)
                    )
                    .foregroundStyle(memoryColor)
                    .symbolSize(34)
                case .energy:
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Energy impact (pts)", point.primary)
                    )
                    .foregroundStyle(Theme.energy)
                    .symbolSize(34)
                case .disk:
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Read (bytes/s)", point.primary)
                    )
                    .foregroundStyle(Theme.inbound)
                    .symbolSize(34)

                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Write (bytes/s)", point.secondary ?? 0)
                    )
                    .foregroundStyle(Theme.outbound)
                    .symbolSize(34)
                case .network:
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Received (bytes/s)", point.primary)
                    )
                    .foregroundStyle(Theme.inbound)
                    .symbolSize(34)

                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Sent (bytes/s)", point.secondary ?? 0)
                    )
                    .foregroundStyle(Theme.outbound)
                    .symbolSize(34)
                }
            }
        }
    }

    @ViewBuilder
    private var legend: some View {
        switch metric {
        case .cpu:
            legendItem("System", color: Theme.cpuSystem)
            legendItem("User", color: Theme.cpuUser)
        case .memory:
            legendItem("Pressure", color: memoryColor)
        case .energy:
            legendItem("Relative impact", color: Theme.energy)
                .help("Energy impact is a relative score in points, not power in watts.")
        case .disk:
            legendItem("Read", color: Theme.inbound)
            legendItem("Write", color: Theme.outbound, dashed: true)
        case .network:
            legendItem("Received", color: Theme.inbound)
            legendItem("Sent", color: Theme.outbound, dashed: true)
        }
    }

    private func legendItem(_ title: String, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 2))
                path.addLine(to: CGPoint(x: 14, y: 2))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
            .frame(width: 14, height: 4)
            .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
        }
    }

    private var startupStatus: some View {
        HStack(spacing: 7) {
            if reduceMotion {
                Image(systemName: "waveform.path.ecg")
                    .foregroundColor(accentColor)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(accentColor)
            }

            Text(history.isEmpty ? "Collecting first sample…" : "Building 5-minute history…")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.68))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.62))
                .overlay(Capsule().stroke(accentColor.opacity(0.22)))
        )
        .accessibilityElement(children: .combine)
    }

    private var isStartingUp: Bool {
        history.count < 2
    }

    private var timeDomain: ClosedRange<Date> {
        let interval = TimeInterval(ResourceSamplingPolicy.forMetric(metric).intervalSeconds)
        let latest = max(history.last?.date ?? .distantPast, Date())
        let end = latest.addingTimeInterval(interval / 2)
        return end.addingTimeInterval(-historyWindow)...end
    }

    private var chartScale: ResourceChartScale {
        ResourceChartScale(
            metric: metric,
            maximumValue: history.map { max($0.primary, $0.secondary ?? 0) }.max() ?? 0
        )
    }

    private var accentColor: Color {
        switch metric {
        case .cpu: return Theme.cpuUser
        case .memory: return memoryColor
        case .energy: return Theme.energy
        case .disk, .network: return Theme.inbound
        }
    }

    private var historyWindow: TimeInterval { 300 }

    private var memoryColor: Color {
        let value = pressure ?? 0
        if value >= 90 { return .red }
        if value >= 75 { return .yellow }
        return Theme.memory
    }
}

private struct ResourceValue: View {
    let label: String
    let value: String
    var color: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.7)
                .foregroundColor(.white.opacity(0.36))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(color.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.raisedPanel)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
        )
    }
}

private struct DiskCapacityBreakdown: View {
    let capacity: DiskCapacity?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Disk space", systemImage: "internaldrive.fill")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                    .foregroundColor(.white.opacity(0.58))

                Spacer()

                Text(occupiedPercentage)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.52))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.memory.opacity(capacity == nil ? 0.12 : 0.72))

                    if let capacity {
                        Capsule()
                            .fill(occupiedColor)
                            .frame(width: proxy.size.width * CGFloat(capacity.occupiedFraction))
                    }
                }
            }
            .frame(height: 8)

            HStack(spacing: 18) {
                capacityValue(
                    label: "Occupied",
                    value: capacity.map { formatBytes($0.occupiedBytes) } ?? "—",
                    color: occupiedColor
                )
                capacityValue(
                    label: "Free",
                    value: capacity.map { formatBytes($0.freeBytes) } ?? "—",
                    color: Theme.memory
                )

                Spacer(minLength: 8)

                capacityValue(
                    label: "Total",
                    value: capacity.map { formatBytes($0.totalBytes) } ?? "—",
                    color: .white.opacity(0.72)
                )
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.raisedPanel)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var occupiedColor: Color {
        let fraction = capacity?.occupiedFraction ?? 0
        if fraction >= 0.9 { return .red }
        if fraction >= 0.75 { return .yellow }
        return Theme.diskOccupied
    }

    private var occupiedPercentage: String {
        guard let capacity else { return "Unavailable" }
        return String(format: "%.0f%% occupied", capacity.occupiedFraction * 100)
    }

    private var accessibilityText: String {
        guard let capacity else { return "Disk space unavailable" }
        return "Disk space: \(formatBytes(capacity.occupiedBytes)) occupied, \(formatBytes(capacity.freeBytes)) free, \(formatBytes(capacity.totalBytes)) total"
    }

    private func capacityValue(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 8, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundColor(.white.opacity(0.34))
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.86))
                    .lineLimit(1)
            }
        }
    }
}
