import SwiftUI
import Charts

/// A single sampled energy-impact data point for one process at one moment.
struct EnergyTrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let pid: Int32
    let name: String
    let power: Double
}

/// Tracks the current top energy consumers (macOS `top` POWER metric) and
/// accumulates a usage trend sampled on a configurable interval
/// (default every 10 minutes, 12h rolling window).
final class EnergyMonitor: ObservableObject {
    @Published var topByPower: [ProcessEntry] = []
    @Published var trend: [EnergyTrendPoint] = []
    @Published var intervalSeconds: Int = 600 {
        didSet { rescheduleTrend() }
    }

    static let intervalOptions = TopConsumersMonitor.intervalOptions

    var intervalLabel: String {
        Self.intervalOptions.first { $0.seconds == intervalSeconds }?.label ?? "\(intervalSeconds)s"
    }

    private var listTimer: DispatchSourceTimer?
    private var trendTimer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private let timerQueue = DispatchQueue(label: "killswitch.energy.timer", qos: .userInitiated)
    private var started = false
    private let username = NSUserName()
    private static let windowSeconds: TimeInterval = 12 * 3600
    private let topCount = 10

    func start() {
        guard !started else { return }
        started = true
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .automaticTerminationDisabled],
                reason: "Continuously sampling top energy consumers"
            )
        }
        refreshList()
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
            self?.refreshList()
        }
    }

    /// Names of the processes currently in the top set, ordered by energy impact
    /// (highest first) with duplicates removed so it can drive the chart legend.
    var trendNames: [String] {
        let latest = topByPower.prefix(topCount).map { $0.name }
        var seen: Set<String> = []
        return latest.filter { seen.insert($0).inserted }
    }

    /// Trend points limited to the processes currently in the top set.
    var filteredTrend: [EnergyTrendPoint] {
        let names = Set(trendNames)
        return trend.filter { names.contains($0.name) }
    }

    private func startListTimer() {
        listTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.refreshList() }
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

    private func refreshList() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let entries = ProcessSampler.fetchCollapsed(user: self.username, includePower: true)
            let byPower = Array(entries.sorted { $0.power > $1.power }.prefix(self.topCount))
            DispatchQueue.main.async { self.topByPower = byPower }
        }
    }

    private func appendTrendSample() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let entries = ProcessSampler.fetchCollapsed(user: self.username, includePower: true)
            let byPower = Array(entries.sorted { $0.power > $1.power }.prefix(self.topCount))
            let now = Date()
            let points = byPower.map {
                EnergyTrendPoint(date: now, pid: $0.pid, name: $0.name, power: $0.power)
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

struct EnergyTab: View {
    @ObservedObject var monitor: EnergyMonitor

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    trendSection
                    listSection
                }
                .padding(16)
            }
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack {
            Image(systemName: "bolt.fill")
                .foregroundColor(.yellow)
            Text("Energy")
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
                Text("Energy impact trend (12h window)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Picker("Every", selection: $monitor.intervalSeconds) {
                    ForEach(EnergyMonitor.intervalOptions, id: \.seconds) { option in
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
                        y: .value("Energy", point.power)
                    )
                    .foregroundStyle(by: .value("Process", point.name))
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Energy", point.power)
                    )
                    .foregroundStyle(by: .value("Process", point.name))
                    .symbolSize(20)
                }
                .chartForegroundStyleScale(domain: monitor.trendNames)
                .chartYAxisLabel("Energy impact")
                .frame(height: 240)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.2)))
            }
        }
    }

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top 10 by energy impact")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            if monitor.topByPower.isEmpty {
                Text("No data yet.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ForEach(Array(monitor.topByPower.enumerated()), id: \.element.pid) { index, entry in
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
                        Text(String(format: "%.1f", entry.power))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.yellow.opacity(0.9))
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
