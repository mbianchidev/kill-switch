import SwiftUI
import Charts

enum TrendMetric: String, CaseIterable {
    case cpu = "CPU"
    case memory = "Memory"
}

/// A single sampled data point for one process at one moment in time.
struct TrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let pid: Int32
    let name: String
    let cpu: Double
    let memory: Double
}

/// Tracks the current top CPU/memory consumers and accumulates a usage trend
/// sampled on a configurable interval (default every 10 minutes, 12h window).
final class TopConsumersMonitor: ObservableObject {
    @Published var topByCPU: [ProcessEntry] = []
    @Published var topByMemory: [ProcessEntry] = []
    @Published var trend: [TrendPoint] = []
    @Published var trendMetric: TrendMetric = .memory
    @Published var intervalSeconds: Int = 600 {
        didSet { rescheduleTrend() }
    }

    /// Interval options for the trend sampler (includes 30s/1m debug intervals).
    static let intervalOptions: [(label: String, seconds: Int)] = [
        ("30s", 30), ("1m", 60), ("5m", 300), ("10m", 600), ("15m", 900), ("30m", 1800), ("60m", 3600)
    ]

    var intervalLabel: String {
        Self.intervalOptions.first { $0.seconds == intervalSeconds }?.label ?? "\(intervalSeconds)s"
    }

    private var listTimer: DispatchSourceTimer?
    private var trendTimer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private let timerQueue = DispatchQueue(label: "killswitch.topconsumers.timer", qos: .userInitiated)
    private var started = false
    private let username = NSUserName()
    private static let windowSeconds: TimeInterval = 12 * 3600
    private let topCount = 10

    func start() {
        guard !started else { return }
        started = true
        // Prevent App Nap so sampling keeps running when the app is unfocused or
        // a different tab is shown.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .automaticTerminationDisabled],
                reason: "Continuously sampling top process consumers"
            )
        }
        refreshLists()
        appendTrendSample()
        startListTimer()
        rescheduleTrend()
    }

    func stop() {
        started = false
        listTimer?.cancel(); listTimer = nil
        trendTimer?.cancel(); trendTimer = nil
        if let activity = activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    func kill(pid: Int32) {
        ProcessSampler.terminate(pid: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshLists()
        }
    }

    /// Names of the processes currently in the top set for the selected metric.
    var trendNames: [String] {
        let latest = topForMetric(trendMetric)
        return Array(latest.prefix(topCount).map { $0.name })
    }

    /// Trend points limited to the processes currently in the top set.
    var filteredTrend: [TrendPoint] {
        let names = Set(trendNames)
        return trend.filter { names.contains($0.name) }
    }

    func value(for point: TrendPoint) -> Double {
        trendMetric == .cpu ? point.cpu : point.memory
    }

    private func topForMetric(_ metric: TrendMetric) -> [ProcessEntry] {
        metric == .cpu ? topByCPU : topByMemory
    }

    private func startListTimer() {
        listTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.refreshLists() }
        timer.resume()
        listTimer = timer
    }

    private func rescheduleTrend() {
        trendTimer?.cancel()
        let interval = TimeInterval(max(5, intervalSeconds))
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.appendTrendSample() }
        timer.resume()
        trendTimer = timer
    }

    private func refreshLists() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let entries = ProcessSampler.fetchCollapsed(user: self.username)
            let byCPU = Array(entries.sorted { $0.cpu > $1.cpu }.prefix(self.topCount))
            let byMem = Array(entries.sorted { $0.memory > $1.memory }.prefix(self.topCount))
            DispatchQueue.main.async {
                self.topByCPU = byCPU
                self.topByMemory = byMem
            }
        }
    }

    private func appendTrendSample() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let entries = ProcessSampler.fetchCollapsed(user: self.username)
            let byCPU = Array(entries.sorted { $0.cpu > $1.cpu }.prefix(self.topCount))
            let byMem = Array(entries.sorted { $0.memory > $1.memory }.prefix(self.topCount))

            // Union of the current top CPU and top memory consumers.
            var seen: Set<Int32> = []
            let now = Date()
            var points: [TrendPoint] = []
            for entry in byCPU + byMem where seen.insert(entry.pid).inserted {
                points.append(
                    TrendPoint(date: now, pid: entry.pid, name: entry.name, cpu: entry.cpu, memory: entry.memory)
                )
            }

            DispatchQueue.main.async {
                self.trend.append(contentsOf: points)
                let cutoff = now.addingTimeInterval(-Self.windowSeconds)
                self.trend.removeAll { $0.date < cutoff }
            }
        }
    }
}

// MARK: - View

struct TopConsumersTab: View {
    @ObservedObject var monitor: TopConsumersMonitor

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    trendSection
                    listSection(title: "Top 10 by CPU", entries: monitor.topByCPU, metric: .cpu)
                    listSection(title: "Top 10 by memory", entries: monitor.topByMemory, metric: .memory)
                }
                .padding(16)
            }
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack {
            Image(systemName: "chart.bar")
                .foregroundColor(.cyan)
            Text("Top consumers")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Trend (12h window)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Picker("", selection: $monitor.trendMetric) {
                    ForEach(TrendMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Picker("Every", selection: $monitor.intervalSeconds) {
                    ForEach(TopConsumersMonitor.intervalOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 90)
            }

            if monitor.filteredTrend.isEmpty {
                Text("Collecting samples… first point captured on load, then every \(monitor.intervalLabel).")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(height: 200)
            } else {
                Chart(monitor.filteredTrend) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(monitor.trendMetric.rawValue, monitor.value(for: point))
                    )
                    .foregroundStyle(by: .value("Process", point.name))
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("Time", point.date),
                        y: .value(monitor.trendMetric.rawValue, monitor.value(for: point))
                    )
                    .foregroundStyle(by: .value("Process", point.name))
                    .symbolSize(20)
                }
                .chartYAxisLabel(monitor.trendMetric == .cpu ? "CPU %" : "Memory (MB)")
                .frame(height: 240)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.2)))
            }
        }
    }

    private func listSection(title: String, entries: [ProcessEntry], metric: TrendMetric) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            if entries.isEmpty {
                Text("No data yet.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.pid) { index, entry in
                    HStack(spacing: 12) {
                        Text("\(index + 1).")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 24, alignment: .trailing)
                        Text(entry.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("PID \(entry.pid)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                        Spacer()
                        Text(metric == .cpu
                             ? String(format: "%.1f%%", entry.cpu)
                             : formatMemory(entry.memory))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.cyan.opacity(0.9))
                            .frame(width: 80, alignment: .trailing)
                        KillButton(pid: entry.pid) { monitor.kill(pid: entry.pid) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                }
            }
        }
    }
}
