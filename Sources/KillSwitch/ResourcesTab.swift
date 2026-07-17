import Charts
import SwiftUI

struct ResourcesTab: View {
    @ObservedObject var monitor: ResourceMonitor
    @State private var metric: ResourceMetric = .cpu
    @State private var sort: ResourceSort = .cpu
    @State private var searchText = ""
    @State private var selectedPID: Int32?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            processTable
            Divider()
            instrumentRail
        }
        .background(Theme.background)
        .onChange(of: metric) { newMetric in
            sort = ResourceSort.defaultOption(for: newMetric)
            monitor.setMetric(newMetric)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Label("Resources", systemImage: "waveform.path.ecg")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                Picker("Resource", selection: $metric) {
                    ForEach(ResourceMetric.allCases) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 430)

                Spacer()

                Picker("Process scope", selection: $monitor.showAllUsers) {
                    Text("My processes").tag(false)
                    Text("All processes").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
                .help("Show only \(monitor.currentUsername), or include root and other users")
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.white.opacity(0.45))
                    TextField("Filter by process, PID, or user", text: $searchText)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.22))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                )

                Picker("Sort", selection: $sort) {
                    ForEach(ResourceSort.options(for: metric)) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)

                Button {
                    monitor.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")

                Text("\(visibleProcesses.count) processes")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))

                Spacer()

                if let lastUpdated = monitor.lastUpdated {
                    Text("Updated \(lastUpdated.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                } else {
                    Text("Collecting system metrics…")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            if let error = monitor.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    private var processTable: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(visibleProcesses.enumerated()), id: \.element.pid) { index, process in
                        ResourceProcessRow(
                            process: process,
                            metric: metric,
                            isSelected: selectedPID == process.pid,
                            isAlternate: index.isMultiple(of: 2) == false,
                            onSelect: { selectedPID = process.pid },
                            onKill: { monitor.kill(pid: process.pid) }
                        )
                    }
                } header: {
                    ResourceTableHeader(metric: metric)
                }
            }
            .frame(minWidth: tableWidth, alignment: .leading)
        }
        .background(Color.black.opacity(0.08))
    }

    private var instrumentRail: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(chartTitle)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(.white.opacity(0.5))

                ResourceHistoryChart(
                    metric: metric,
                    history: monitor.history[metric] ?? [],
                    pressure: monitor.memory.pressurePercent
                )
                    .frame(minWidth: 320, idealWidth: 390, maxWidth: 440, minHeight: 105, maxHeight: 105)
            }

            Divider()

            summaryValues
                .frame(maxWidth: .infinity, alignment: .leading)
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
                ResourceValue(label: "System", value: percent(monitor.cpu.systemPercent), color: Theme.cpuSystem)
                ResourceValue(label: "User", value: percent(monitor.cpu.userPercent), color: Theme.cpuUser)
                ResourceValue(label: "Idle", value: percent(monitor.cpu.idlePercent))
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
                    label: "Energy impact",
                    value: String(format: "%.1f", monitor.processes.reduce(0) { $0 + $1.power }),
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
            FlowLayout(spacing: 10) {
                ResourceValue(label: "Reads in", value: formatNumber(monitor.disk.reads))
                ResourceValue(label: "Data read", value: formatBytes(monitor.disk.readBytes), color: Theme.inbound)
                ResourceValue(label: "Writes out", value: formatNumber(monitor.disk.writes))
                ResourceValue(label: "Data written", value: formatBytes(monitor.disk.writtenBytes), color: Theme.outbound)
                ResourceValue(label: "Reads in/sec", value: formatRate(monitor.disk.readsPerSecond))
                ResourceValue(label: "Data read/sec", value: formatByteRate(monitor.disk.readBytesPerSecond))
                ResourceValue(label: "Writes out/sec", value: formatRate(monitor.disk.writesPerSecond))
                ResourceValue(label: "Data written/sec", value: formatByteRate(monitor.disk.writtenBytesPerSecond))
            }
        case .network:
            FlowLayout(spacing: 10) {
                ResourceValue(label: "Packets in", value: formatNumber(monitor.network.receivedPackets))
                ResourceValue(label: "Data received", value: formatBytes(monitor.network.receivedBytes), color: Theme.inbound)
                ResourceValue(label: "Packets out", value: formatNumber(monitor.network.sentPackets))
                ResourceValue(label: "Data sent", value: formatBytes(monitor.network.sentBytes), color: Theme.outbound)
                ResourceValue(label: "Packets in/sec", value: formatRate(monitor.network.receivedPacketsPerSecond))
                ResourceValue(label: "Data received/sec", value: formatByteRate(monitor.network.receivedBytesPerSecond))
                ResourceValue(label: "Packets out/sec", value: formatRate(monitor.network.sentPacketsPerSecond))
                ResourceValue(label: "Data sent/sec", value: formatByteRate(monitor.network.sentBytesPerSecond))
            }
        }
    }

    private var visibleProcesses: [ResourceProcess] {
        var result = monitor.processes
        if !monitor.showAllUsers {
            result = result.filter { $0.user == monitor.currentUsername }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                $0.user.localizedCaseInsensitiveContains(query) ||
                String($0.pid).contains(query)
            }
        }

        switch sort {
        case .cpu:
            result.sort { $0.cpu > $1.cpu }
        case .memory:
            result.sort { $0.memoryBytes > $1.memoryBytes }
        case .energy:
            result.sort { $0.power > $1.power }
        case .diskWritten:
            result.sort { ($0.diskWrittenBytes ?? 0) > ($1.diskWrittenBytes ?? 0) }
        case .diskRead:
            result.sort { ($0.diskReadBytes ?? 0) > ($1.diskReadBytes ?? 0) }
        case .networkReceived:
            result.sort { $0.receivedBytes > $1.receivedBytes }
        case .networkSent:
            result.sort { $0.sentBytes > $1.sentBytes }
        case .name:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid:
            result.sort { $0.pid < $1.pid }
        }
        return result
    }

    private var chartTitle: String {
        switch metric {
        case .cpu: return "CPU LOAD · LAST 5 MINUTES"
        case .memory: return "MEMORY PRESSURE · LAST 5 MINUTES"
        case .energy: return "ENERGY IMPACT · LAST 5 MINUTES"
        case .disk: return "DISK THROUGHPUT · LAST 5 MINUTES"
        case .network: return "NETWORK THROUGHPUT · LAST 5 MINUTES"
        }
    }

    private var tableWidth: CGFloat {
        switch metric {
        case .cpu: return 1_230
        case .memory: return 720
        case .energy: return 880
        case .disk: return 750
        case .network: return 970
        }
    }

    private var memoryPressureColor: Color {
        let pressure = monitor.memory.pressurePercent ?? 0
        if pressure >= 90 { return .red }
        if pressure >= 75 { return .yellow }
        return Theme.memory
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

private struct ResourceTableHeader: View {
    let metric: ResourceMetric

    var body: some View {
        HStack(spacing: 0) {
            ResourceTableCell("Process Name", width: 250, alignment: .leading, isHeader: true)
            switch metric {
            case .cpu:
                ResourceTableCell("% CPU", width: 72, isHeader: true)
                ResourceTableCell("CPU Time", width: 98, isHeader: true)
                ResourceTableCell("Threads", width: 72, isHeader: true)
                ResourceTableCell("Idle Wake Ups", width: 104, isHeader: true)
                ResourceTableCell("Kind", width: 72, isHeader: true)
                ResourceTableCell("% GPU", width: 72, isHeader: true)
                ResourceTableCell("GPU Time", width: 90, isHeader: true)
                ResourceTableCell("PID", width: 72, isHeader: true)
                ResourceTableCell("User", width: 140, alignment: .leading, isHeader: true)
            case .memory:
                ResourceTableCell("Memory", width: 100, isHeader: true)
                ResourceTableCell("Threads", width: 76, isHeader: true)
                ResourceTableCell("Open Files", width: 86, isHeader: true)
                ResourceTableCell("PID", width: 72, isHeader: true)
                ResourceTableCell("User", width: 140, alignment: .leading, isHeader: true)
            case .energy:
                ResourceTableCell("Energy Impact", width: 110, isHeader: true)
                ResourceTableCell("12 hr Power", width: 100, isHeader: true)
                ResourceTableCell("App Nap", width: 82, isHeader: true)
                ResourceTableCell("Preventing Sleep", width: 120, isHeader: true)
                ResourceTableCell("PID", width: 72, isHeader: true)
                ResourceTableCell("User", width: 140, alignment: .leading, isHeader: true)
            case .disk:
                ResourceTableCell("Bytes Written", width: 118, isHeader: true)
                ResourceTableCell("Bytes Read", width: 118, isHeader: true)
                ResourceTableCell("PID", width: 72, isHeader: true)
                ResourceTableCell("User", width: 140, alignment: .leading, isHeader: true)
            case .network:
                ResourceTableCell("Sent Bytes", width: 110, isHeader: true)
                ResourceTableCell("Rcvd Bytes", width: 110, isHeader: true)
                ResourceTableCell("Sent Packets", width: 110, isHeader: true)
                ResourceTableCell("Rcvd Packets", width: 110, isHeader: true)
                ResourceTableCell("PID", width: 72, isHeader: true)
                ResourceTableCell("User", width: 140, alignment: .leading, isHeader: true)
            }
            ResourceTableCell("", width: 42, isHeader: true)
        }
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
    let onSelect: () -> Void
    let onKill: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            processName
            switch metric {
            case .cpu:
                value(String(format: "%.1f", process.cpu), width: 72, color: Theme.cpuUser)
                value(formatDuration(process.cpuTimeSeconds), width: 98)
                value(
                    process.threads.map(String.init) ?? "—",
                    width: 72,
                    help: unavailableHelp(process.threads)
                )
                value(process.idleWakeUps.map(formatNumber) ?? "—", width: 104)
                value(process.kind ?? "—", width: 72, help: unavailableHelp(process.kind))
                value(process.gpu.map { String(format: "%.1f", $0) } ?? "—", width: 72, help: gpuHelp)
                value(
                    process.gpuTimeSeconds.map(formatDuration) ?? "—",
                    width: 90,
                    help: gpuHelp
                )
                value("\(process.pid)", width: 72)
                value(process.user, width: 140, alignment: .leading)
            case .memory:
                value(formatBytes(process.memoryBytes), width: 100, color: Theme.memory)
                value(
                    process.threads.map(String.init) ?? "—",
                    width: 76,
                    help: unavailableHelp(process.threads)
                )
                value(
                    process.openFileCount.map(String.init) ?? "—",
                    width: 86,
                    help: unavailableHelp(process.openFileCount)
                )
                value("\(process.pid)", width: 72)
                value(process.user, width: 140, alignment: .leading)
            case .energy:
                value(String(format: "%.1f", process.power), width: 110, color: Theme.energy)
                value(
                    process.power12Hour.map { String(format: "%.2f", $0) } ?? "—",
                    width: 100
                )
                value(boolean(process.appNap), width: 82, help: appNapHelp)
                value(process.preventsSleep ? "Yes" : "No", width: 120)
                value("\(process.pid)", width: 72)
                value(process.user, width: 140, alignment: .leading)
            case .disk:
                value(
                    process.diskWrittenBytes.map(formatBytes) ?? "—",
                    width: 118,
                    color: Theme.outbound,
                    help: unavailableHelp(process.diskWrittenBytes)
                )
                value(
                    process.diskReadBytes.map(formatBytes) ?? "—",
                    width: 118,
                    color: Theme.inbound,
                    help: unavailableHelp(process.diskReadBytes)
                )
                value("\(process.pid)", width: 72)
                value(process.user, width: 140, alignment: .leading)
            case .network:
                value(formatBytes(process.sentBytes), width: 110, color: Theme.outbound)
                value(formatBytes(process.receivedBytes), width: 110, color: Theme.inbound)
                value(formatNumber(process.sentPackets), width: 110)
                value(formatNumber(process.receivedPackets), width: 110)
                value("\(process.pid)", width: 72)
                value(process.user, width: 140, alignment: .leading)
            }

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

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .frame(width: 250, alignment: .leading)
    }

    private var rowBackground: Color {
        if isSelected { return Color.white.opacity(0.11) }
        return isAlternate ? Color.white.opacity(0.025) : .clear
    }

    private var gpuHelp: String {
        "macOS does not expose per-process GPU counters through supported public interfaces."
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
    let isHeader: Bool
    let color: Color
    let helpText: String?

    init(
        _ text: String,
        width: CGFloat,
        alignment: Alignment = .trailing,
        isHeader: Bool = false,
        color: Color = .white.opacity(0.68),
        help: String? = nil
    ) {
        self.text = text
        self.width = width
        self.alignment = alignment
        self.isHeader = isHeader
        self.color = color
        self.helpText = help
    }

    var body: some View {
        Text(text)
            .font(.system(size: isHeader ? 10 : 11, weight: isHeader ? .semibold : .regular, design: .monospaced))
            .foregroundColor(isHeader ? .white.opacity(0.52) : color)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 6)
            .help(helpText ?? "")
    }
}

private struct ResourceHistoryChart: View {
    let metric: ResourceMetric
    let history: [ResourceHistoryPoint]
    let pressure: Double?

    var body: some View {
        Group {
            if history.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.22))
                    Text("Collecting samples…")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                }
            } else {
                chart
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(Color.white.opacity(0.08))
                            AxisValueLabel()
                                .foregroundStyle(Color.white.opacity(0.4))
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.22))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    )
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch metric {
        case .cpu:
            Chart(history) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("Start", 0),
                    yEnd: .value("System", point.primary)
                )
                .foregroundStyle(Theme.cpuSystem.opacity(0.62))
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("System", point.primary),
                    yEnd: .value("User", point.primary + (point.secondary ?? 0))
                )
                .foregroundStyle(Theme.cpuUser.opacity(0.62))
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...100)
        case .memory:
            Chart(history) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Pressure", point.primary)
                )
                .foregroundStyle(memoryColor.opacity(0.55))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Pressure", point.primary)
                )
                .foregroundStyle(memoryColor)
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...100)
        case .energy:
            Chart(history) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Energy", point.primary)
                )
                .foregroundStyle(Theme.energy.opacity(0.4))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Energy", point.primary)
                )
                .foregroundStyle(Theme.energy)
                .interpolationMethod(.monotone)
            }
        case .disk:
            Chart(history) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Read", point.primary)
                )
                .foregroundStyle(Theme.inbound)
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Write", point.secondary ?? 0)
                )
                .foregroundStyle(Theme.outbound)
                .interpolationMethod(.monotone)
            }
        case .network:
            Chart(history) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Received", point.primary)
                )
                .foregroundStyle(Theme.inbound)
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Sent", point.secondary ?? 0)
                )
                .foregroundStyle(Theme.outbound)
                .interpolationMethod(.monotone)
            }
        }
    }

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
