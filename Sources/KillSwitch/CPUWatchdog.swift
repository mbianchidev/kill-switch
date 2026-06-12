import SwiftUI

/// A process currently sustaining high CPU, with how many consecutive checks
/// it has been above the threshold.
struct CPUOffender: Identifiable {
    let id: Int32
    let pid: Int32
    let name: String
    let cpu: Double
    let consecutive: Int
}

/// A fired high-CPU alert, kept for an in-app history list.
struct CPUAlertRecord: Identifiable {
    let id = UUID()
    let date: Date
    let pid: Int32
    let name: String
    let cpu: Double
    let checks: Int
}

/// Watches for processes (parent-collapsed) sustaining CPU above a threshold for
/// several consecutive checks and fires native macOS notifications, mirroring the
/// `cpu-watchdog.sh` / `cpu-hog-monitor.sh` scripts.
///
/// Tracks a per-PID consecutive counter; once it reaches `consecutiveThreshold`
/// an alert is posted and that counter is reset to avoid spamming (it re-alerts
/// after the same number of further consecutive sightings).
final class CPUWatchdog: ObservableObject {
    @Published var offenders: [CPUOffender] = []
    @Published var alerts: [CPUAlertRecord] = []
    @Published var lastRun: Date?
    @Published var threshold: Double = 90 {
        didSet { reset() }
    }
    @Published var consecutiveThreshold: Int = 3
    @Published var intervalSeconds: Int = 300 {
        didSet { reschedule() }
    }

    static let intervalOptions = TopConsumersMonitor.intervalOptions
    static let thresholdOptions: [Double] = [80, 85, 90, 95]
    static let consecutiveOptions: [Int] = [2, 3, 5, 6]

    var intervalLabel: String {
        Self.intervalOptions.first { $0.seconds == intervalSeconds }?.label ?? "\(intervalSeconds)s"
    }

    private var counts: [Int32: Int] = [:]
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private let timerQueue = DispatchQueue(label: "killswitch.watchdog.timer", qos: .userInitiated)
    private var started = false
    private let username = NSUserName()
    private let maxAlerts = 50
    private static let maxLogLines = 500
    private static let logURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/cpu-watchdog.log")

    func start() {
        guard !started else { return }
        started = true
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .automaticTerminationDisabled],
                reason: "Watching for sustained high-CPU processes"
            )
        }
        check()
        reschedule()
    }

    func stop() {
        started = false
        timer?.cancel(); timer = nil
        if let activity = activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    func kill(pid: Int32) {
        ProcessSampler.terminate(pid: pid)
        counts[pid] = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.check()
        }
    }

    /// Run a single watchdog check now.
    func check() {
        let threshold = self.threshold
        let consecutiveThreshold = self.consecutiveThreshold
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let entries = ProcessSampler.fetchCollapsed(user: self.username)
                .filter { $0.cpu >= threshold }
                .sorted { $0.cpu > $1.cpu }

            var newCounts: [Int32: Int] = [:]
            var offenders: [CPUOffender] = []
            var fired: [CPUAlertRecord] = []
            let now = Date()

            for entry in entries {
                let count = (self.counts[entry.pid] ?? 0) + 1
                if count >= consecutiveThreshold {
                    fired.append(
                        CPUAlertRecord(date: now, pid: entry.pid, name: entry.name, cpu: entry.cpu, checks: count)
                    )
                    // Reset after alerting to avoid spam (re-alerts after N more checks).
                    newCounts[entry.pid] = 0
                } else {
                    newCounts[entry.pid] = count
                }
                offenders.append(
                    CPUOffender(id: entry.pid, pid: entry.pid, name: entry.name, cpu: entry.cpu, consecutive: count)
                )
            }

            for record in fired { self.postAlert(record) }
            self.appendLog(offenders: offenders, fired: fired, now: now)

            DispatchQueue.main.async {
                self.counts = newCounts
                self.offenders = offenders
                if !fired.isEmpty {
                    self.alerts.insert(contentsOf: fired.reversed(), at: 0)
                    if self.alerts.count > self.maxAlerts {
                        self.alerts.removeLast(self.alerts.count - self.maxAlerts)
                    }
                }
                self.lastRun = now
            }
        }
    }

    private func reschedule() {
        timer?.cancel()
        let interval = TimeInterval(max(5, intervalSeconds))
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    private func reset() {
        counts.removeAll()
    }

    private func postAlert(_ record: CPUAlertRecord) {
        let minutes = record.checks * max(5, intervalSeconds) / 60
        ProcessSampler.notify(
            title: "🔥 CPU Watchdog",
            subtitle: "Process running hot",
            body: "\(record.name) (PID \(record.pid)) at \(String(format: "%.0f", record.cpu))% CPU for ~\(minutes) min"
        )
    }

    private func appendLog(offenders: [CPUOffender], fired: [CPUAlertRecord], now: Date) {
        guard !offenders.isEmpty else { return }
        let stamp = Self.stampFormatter.string(from: now)
        var lines: [String] = []
        for record in fired {
            lines.append("\(stamp) ⚠️ HIGH CPU ALERT: PID \(record.pid) (\(record.name)) at \(String(format: "%.0f", record.cpu))% CPU for \(record.checks) consecutive checks")
        }
        lines.append("\(stamp) Tracking \(offenders.count) process(es) above \(String(format: "%.0f", threshold))% CPU")
        Self.write(lines: lines)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Append lines to the log file, creating it if needed and trimming to the
    /// last `maxLogLines`. Failures are swallowed: logging must never crash the app.
    private static func write(lines: [String]) {
        let fm = FileManager.default
        let dir = logURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var existing = (try? String(contentsOf: logURL, encoding: .utf8))?
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty } ?? []
        existing.append(contentsOf: lines)
        if existing.count > maxLogLines {
            existing.removeFirst(existing.count - maxLogLines)
        }
        try? (existing.joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - View

struct CPUWatchdogTab: View {
    @ObservedObject var monitor: CPUWatchdog

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    offendersSection
                    alertsSection
                }
                .padding(16)
            }
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text("CPU Watchdog")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Button { monitor.check() } label: {
                Label("Check now", systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                labeledPicker("Threshold") {
                    Picker("", selection: $monitor.threshold) {
                        ForEach(CPUWatchdog.thresholdOptions, id: \.self) {
                            Text("\(Int($0))%").tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 80)
                }
                labeledPicker("Every") {
                    Picker("", selection: $monitor.intervalSeconds) {
                        ForEach(CPUWatchdog.intervalOptions, id: \.seconds) { option in
                            Text(option.label).tag(option.seconds)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 80)
                }
                labeledPicker("Alert after") {
                    Picker("", selection: $monitor.consecutiveThreshold) {
                        ForEach(CPUWatchdog.consecutiveOptions, id: \.self) {
                            Text("\($0) checks").tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
                Spacer()
            }
            Text("Notifies when a process stays above \(Int(monitor.threshold))% CPU for \(monitor.consecutiveThreshold) consecutive checks (~\(monitor.consecutiveThreshold * max(5, monitor.intervalSeconds) / 60) min). Logs to ~/Library/Logs/cpu-watchdog.log.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
            if let last = monitor.lastRun {
                Text("Last check: \(last.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.2)))
    }

    private func labeledPicker<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            content()
        }
    }

    private var offendersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Currently above threshold (\(monitor.offenders.count))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            if monitor.offenders.isEmpty {
                Text("No processes above \(Int(monitor.threshold))% CPU.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ForEach(monitor.offenders) { offender in
                    HStack(spacing: 12) {
                        Text(offender.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("PID \(offender.pid)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                        Spacer()
                        Text("\(offender.consecutive)/\(monitor.consecutiveThreshold)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.orange.opacity(0.9))
                            .help("Consecutive checks above threshold")
                        Text(String(format: "%.0f%%", offender.cpu))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.red.opacity(0.9))
                            .frame(width: 64, alignment: .trailing)
                        KillButton(pid: offender.pid) { monitor.kill(pid: offender.pid) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
                }
            }
        }
    }

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent alerts (\(monitor.alerts.count))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            if monitor.alerts.isEmpty {
                Text("No alerts fired yet.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ForEach(monitor.alerts) { alert in
                    HStack(spacing: 12) {
                        Text(alert.date.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 84, alignment: .leading)
                        Text(alert.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("PID \(alert.pid)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                        Spacer()
                        Text(String(format: "%.0f%%", alert.cpu))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.red.opacity(0.9))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                }
            }
        }
    }
}
