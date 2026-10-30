import Charts
import SwiftUI
import SystemMetricsCore

struct ActivityDashboard: View {
    @ObservedObject var monitor: ResourceMonitor
    @State private var search = ""
    @State private var selectedDate: Date?

    private let metrics: [ResourceMetric] = [.cpu, .memory, .network, .disk]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text(monitor.lastUpdated.map {
                        "Updated \($0.formatted(date: .omitted, time: .standard))"
                    } ?? "Collecting first measurements")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh activity and retry history storage")
                    ProcessScopePicker(monitor: monitor)
                }

                ActivityHistoryControls(monitor: monitor)
                ActivityMonitorErrors(monitor: monitor)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(metrics) { metric in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(metric.rawValue, systemImage: activityIcon(metric))
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(activitySummary(metric))
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            }
                            ActivityTimelineChart(
                                metric: metric, history: monitor.timeline, range: monitor.historyRange,
                                now: monitor.lastUpdated ?? Date(), isProcess: monitor.focusedProcess != nil,
                                selectedDate: selectedDate,
                                onSelect: { selectedDate = $0 }
                            )
                            .frame(height: 140)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                    }
                }

                timelineScrubber

                HStack {
                    Text("Live processes")
                        .font(.system(size: 13, weight: .semibold))
                    TextField("Search process, PID, or user", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 330)
                    Spacer()
                    Text("Select a process to compare all four histories")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Table(liveProcesses, selection: $monitor.focusedProcess) {
                    TableColumn("Process") { Text($0.process.name) }
                        .width(min: 140, ideal: 180)
                    TableColumn("PID") { Text(String($0.process.identity.pid)) }
                        .width(55)
                    TableColumn("CPU") { Text(formatActivityValue($0.values.cpu, metric: .cpu)) }
                        .width(75)
                    TableColumn("Memory") { Text(formatActivityValue($0.values.memory, metric: .memory)) }
                        .width(90)
                    TableColumn("Received/s") { Text(formatByteRate($0.values.received)) }
                        .width(100)
                    TableColumn("Sent/s") { Text(formatByteRate($0.values.sent)) }
                        .width(100)
                    TableColumn("Read/s") { Text(formatByteRate($0.values.diskRead)) }
                        .width(100)
                    TableColumn("Written/s") { Text(formatByteRate($0.values.diskWritten)) }
                        .width(100)
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 230)
                .scrollContentBackground(.hidden)

                Text("Live samples every 6 seconds. History uses one-minute averages and stays on this Mac for 24 hours. Select exited processes from History for. N/A means a measurement is unavailable.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(16)
        }
        .background(Theme.background)
        .onChange(of: monitor.historyRange) { _ in selectedDate = nil }
        .onChange(of: monitor.focusedProcess) { _ in selectedDate = nil }
    }

    private var timelineScrubber: some View {
        HStack(spacing: 10) {
            Label(
                selectedDate?.formatted(date: .omitted, time: .standard) ?? "Live",
                systemImage: selectedDate == nil ? "waveform.path" : "clock"
            )
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 120, alignment: .leading)
            Slider(value: Binding(
                get: {
                    min(1, max(0, (selectedDate ?? end).timeIntervalSince(end.addingTimeInterval(-monitor.historyRange.seconds))
                        / monitor.historyRange.seconds))
                },
                set: { selectedDate = end.addingTimeInterval(($0 - 1) * monitor.historyRange.seconds) }
            ), in: 0...1)
            .accessibilityLabel("Inspect the same time across all four resource charts")
            Button("Live") { selectedDate = nil }
                .disabled(selectedDate == nil)
        }
    }

    private var end: Date { monitor.lastUpdated ?? Date() }

    private var displayedValues: ActivityValues {
        if let selectedDate {
            guard let nearest = monitor.timeline.min(by: {
                abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
            }), abs(nearest.date.timeIntervalSince(selectedDate)) <= 65 else {
                return ActivityValues()
            }
            return nearest.values
        }
        return monitor.liveActivity?.point(for: monitor.focusedProcess).values ?? ActivityValues()
    }

    private func activitySummary(_ metric: ResourceMetric) -> String {
        let pair = displayedValues.pair(for: metric)
        let primary = formatActivityValue(pair.0, metric: metric)
        switch metric {
        case .disk, .network:
            return "\(primary) / \(formatActivityValue(pair.1, metric: metric))"
        default: return primary
        }
    }

    private var liveProcesses: [ActivityProcessSample] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (monitor.liveActivity?.processes ?? []).filter {
            (monitor.showAllUsers || $0.process.user == monitor.currentUsername)
                && (query.isEmpty || [$0.process.name, $0.process.user, String($0.process.identity.pid)]
                    .contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted {
            if ($0.values.cpu ?? -1) != ($1.values.cpu ?? -1) { return ($0.values.cpu ?? -1) > ($1.values.cpu ?? -1) }
            return $0.process.identity.pid < $1.process.identity.pid
        }
    }
}

struct ProcessScopePicker: View {
    @ObservedObject var monitor: ResourceMonitor

    var body: some View {
        Picker("Process scope", selection: $monitor.showAllUsers) {
            Text("My processes").tag(false)
            Text("All processes").tag(true)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 210)
        .help("All processes does not grant administrator access")
        .onChange(of: monitor.showAllUsers) { allUsers in
            if !allUsers, let focused = monitor.historyProcesses.first(where: { $0.id == monitor.focusedProcess }),
               focused.user != monitor.currentUsername {
                monitor.focusedProcess = nil
            }
        }
    }
}

struct ActivityHistoryControls: View {
    @ObservedObject var monitor: ResourceMonitor
    @State private var confirmClear = false
    @State private var processSearch = ""

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Entire Mac") { monitor.focusedProcess = nil }
                Divider()
                ForEach(availableProcesses) { process in
                    Button(processTitle(process)) { monitor.focusedProcess = process.id }
                }
            } label: {
                Label(focusedTitle, systemImage: monitor.focusedProcess == nil ? "desktopcomputer" : "app")
                    .lineLimit(1)
            }
            .frame(maxWidth: 260, alignment: .leading)
            .accessibilityLabel("History for \(focusedTitle)")

            TextField("Find historical process", text: $processSearch)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .help("Filter the History for menu, including exited processes")

            Picker("History range", selection: $monitor.historyRange) {
                ForEach(ActivityHistoryRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 300)
            Spacer(minLength: 0)
            Button("Clear history", role: .destructive) { confirmClear = true }
                .font(.system(size: 11))
        }
        .alert("Clear activity history?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear history", role: .destructive) { monitor.clearHistory() }
        } message: {
            Text("Delete saved CPU, memory, traffic, and disk measurements and process names from this Mac. New measurements will continue.")
        }
    }

    private var focusedTitle: String {
        guard let id = monitor.focusedProcess else { return "History for: Entire Mac" }
        return monitor.historyProcesses.first { $0.id == id }.map {
            "History for: \($0.name) (\(id.pid))"
        } ?? "History for: PID \(id.pid)"
    }

    private var availableProcesses: [ActivityProcessDescriptor] {
        monitor.historyProcesses.filter {
            (monitor.showAllUsers || $0.user == monitor.currentUsername)
                && (processSearch.isEmpty || [$0.name, $0.user, String($0.identity.pid)]
                    .contains { $0.localizedCaseInsensitiveContains(processSearch) })
        }
    }

    private func processTitle(_ process: ActivityProcessDescriptor) -> String {
        let live = monitor.processes.contains { $0.identity == process.id }
        let started = Date(timeIntervalSince1970: Double(process.identity.startTime) / 1_000_000)
        return "\(process.name) (\(process.identity.pid), \(started.formatted(date: .omitted, time: .standard)))\(live ? "" : " [exited]")"
    }
}

struct ActivityMonitorErrors: View {
    @ObservedObject var monitor: ResourceMonitor

    var body: some View {
        if let error = monitor.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .textSelection(.enabled)
        }
        if let error = monitor.historyError {
            Label(error, systemImage: "externaldrive.badge.exclamationmark")
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .textSelection(.enabled)
        }
    }
}

struct ActivityTimelineChart: View {
    let metric: ResourceMetric
    let history: [ActivityHistoryPoint]
    let range: ActivityHistoryRange
    let now: Date
    var isProcess = false
    var selectedDate: Date?
    var onSelect: ((Date) -> Void)?

    var body: some View {
        let splitCPU = metric == .cpu && !isProcess && history.allSatisfy {
            $0.values.cpu == nil || ($0.values.cpuSystem != nil && $0.values.cpuUser != nil)
        }
        let points = ActivitySeries.points(history, metric: metric, splitCPU: splitCPU)
        let scale = chartScale(points: points)
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(points) { point in
                    if splitCPU {
                        AreaMark(
                            x: .value("Time", point.date),
                            yStart: .value("Start", point.lowerBound),
                            yEnd: .value("CPU (%)", point.value),
                            series: .value("CPU band", "\(point.secondary)/\(point.segment)")
                        )
                        .foregroundStyle(traceColor(point, splitCPU: splitCPU).opacity(0.3))
                        .interpolationMethod(.linear)
                    }
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Value", point.value),
                        series: .value("Trace", "\(point.secondary)/\(point.segment)")
                    )
                    .foregroundStyle(traceColor(point, splitCPU: splitCPU))
                    .lineStyle(StrokeStyle(lineWidth: 1.6, dash: point.secondary && metric != .cpu ? [4, 3] : []))
                    .interpolationMethod(.linear)
                    PointMark(x: .value("Time", point.date), y: .value("Value", point.value))
                        .foregroundStyle(traceColor(point, splitCPU: splitCPU))
                        .symbolSize(points.count < 4 ? 18 : 2)
                }
                if let selectedDate {
                    RuleMark(x: .value("Inspect time", selectedDate))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            .chartXScale(domain: now.addingTimeInterval(-range.seconds)...now.addingTimeInterval(3))
            .chartYScale(domain: 0...scale.maximum)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) {
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 9))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: scale.ticks) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(axisLabel(number, scale: scale))
                                .font(.system(size: 9, design: .monospaced))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                if onSelect != nil {
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                                let origin = geometry[proxy.plotAreaFrame].origin
                                if let date: Date = proxy.value(atX: gesture.location.x - origin.x) {
                                    onSelect?(min(now, max(now.addingTimeInterval(-range.seconds), date)))
                                }
                            })
                    }
                }
            }
            .overlay {
                if points.isEmpty {
                    Text("No measurements in this range")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(metric.rawValue) history, \(range.rawValue)")
            .accessibilityValue(accessibilitySummary)

            HStack(spacing: 12) {
                if splitCPU {
                    chartLegend("System", color: Theme.cpuSystem, dashed: false)
                    chartLegend("User", color: Theme.cpuUser, dashed: false)
                } else if metric == .disk || metric == .network {
                    chartLegend(metric == .disk ? "Read" : "Received", color: accent, dashed: false)
                    chartLegend(metric == .disk ? "Written" : "Sent", color: Theme.outbound, dashed: true)
                } else {
                    Text(metric == .cpu ? (isProcess ? "100% = one CPU core" : "Total CPU usage") : "Memory used")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var accessibilitySummary: String {
        let point: ActivityHistoryPoint?
        if let selectedDate {
            point = history.min {
                abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
            }.flatMap { abs($0.date.timeIntervalSince(selectedDate)) <= 65 ? $0 : nil }
        } else { point = history.last }
        let pair = point?.values.pair(for: metric) ?? (nil, nil)
        return "\(formatActivityValue(pair.0, metric: metric))\(pair.1.map { ", \(formatActivityValue($0, metric: metric))" } ?? ""). Gaps mean no measurement."
    }

    private var accent: Color {
        switch metric {
        case .cpu: return Theme.cpuUser
        case .memory: return Theme.memory
        case .disk, .network: return Theme.inbound
        case .energy: return Theme.energy
        }
    }

    private func traceColor(_ point: ActivitySeriesPoint, splitCPU: Bool) -> Color {
        if splitCPU { return point.secondary ? Theme.cpuUser : Theme.cpuSystem }
        return point.secondary ? Theme.outbound : accent
    }

    private func chartScale(points: [ActivitySeriesPoint]) -> ResourceChartScale {
        let maximum = points.map(\.value).max() ?? 0
        if metric == .memory { return ResourceChartScale(metric: .disk, maximumValue: maximum) }
        if metric == .cpu && isProcess && maximum > 100 {
            return ResourceChartScale(metric: .energy, maximumValue: maximum)
        }
        return ResourceChartScale(metric: metric, maximumValue: maximum)
    }

    private func axisLabel(_ value: Double, scale: ResourceChartScale) -> String {
        if metric == .cpu { return "\(value.formatted(.number.precision(.fractionLength(0))))%" }
        let label = scale.label(for: value)
        return metric == .memory ? label.replacingOccurrences(of: "/s", with: "") : label
    }

    private func chartLegend(_ text: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: 16, y: 0))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : []))
            .frame(width: 16, height: 2)
            .accessibilityHidden(true)
            Text(text).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }
}

func formatActivityValue(_ value: Double?, metric: ResourceMetric) -> String {
    guard let value else { return "N/A" }
    switch metric {
    case .cpu: return String(format: "%.1f%%", value)
    case .memory:
        return value < Double(UInt64.max) ? formatBytes(UInt64(value)) : "\(value.formatted()) bytes"
    case .disk, .network: return formatByteRate(value)
    case .energy: return String(format: "%.1f pts", value)
    }
}

private func activityIcon(_ metric: ResourceMetric) -> String {
    switch metric {
    case .cpu: return "cpu"
    case .memory: return "memorychip"
    case .network: return "network"
    case .disk: return "internaldrive"
    case .energy: return "bolt"
    }
}
