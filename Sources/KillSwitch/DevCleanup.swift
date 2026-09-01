import AppKit
import SwiftUI
import DevCleanupCore

/// Lists processes on notable dev ports and auto-kills long-running dev servers
/// owned by the current user, while protecting system/IDE/MCP/Copilot processes.
///
/// Every detection input — the watched ports, the runtime binaries, the dev-server
/// command signatures and the protected-process exclusions — plus the age threshold
/// and scan/cleanup intervals are user-configurable and persisted to `UserDefaults`.
final class DevCleanupMonitor: ObservableObject {
    @Published var portProcesses: [PortProcess] = []
    @Published var cleaned: [CleanedProcess] = []
    @Published var candidateCount: Int = 0
    @Published var lastRun: Date?

    // MARK: - Configuration (persisted)

    /// Whether long-running dev servers are auto-terminated. When off, the tab only
    /// lists ports/dev servers and leaves killing to the manual buttons.
    @Published var autoKillEnabled: Bool {
        didSet { preferences.setAutoKillEnabled(autoKillEnabled) }
    }
    /// Age (in hours) a dev server must exceed before it is auto-killed.
    @Published var ageThresholdHours: Int {
        didSet { preferences.setAgeThresholdHours(ageThresholdHours) }
    }
    /// How often (seconds) the listening-ports list is refreshed.
    @Published var portScanIntervalSeconds: Int {
        didSet {
            preferences.setPortScanIntervalSeconds(portScanIntervalSeconds)
            reschedule()
        }
    }
    /// How often (seconds) the auto-cleanup pass runs.
    @Published var cleanupIntervalSeconds: Int {
        didSet {
            preferences.setCleanupIntervalSeconds(cleanupIntervalSeconds)
            reschedule()
        }
    }
    /// The watched dev ports. A process listening on any of these is always listed.
    @Published var ports: [Int] {
        didSet { preferences.setUserPorts(ports) }
    }
    /// Runtime binaries that indicate a dev server (matched on the executable name).
    @Published var runtimes: [String] {
        didSet { preferences.setRuntimes(runtimes) }
    }
    /// Command-line signatures that mark a process as an actual dev server.
    @Published var devIndicators: [String] {
        didSet { preferences.setIndicators(devIndicators) }
    }
    /// Substrings that protect a process from being auto-killed.
    @Published var exclusions: [String] {
        didSet { preferences.setExclusions(exclusions) }
    }

    var ageThresholdSeconds: Int { ageThresholdHours * 3600 }

    /// Picker options shared with the UI.
    static let intervalOptions = SamplingIntervals.standard
    static let ageOptions: [Int] = [1, 6, 12, 24, 48, 72]
    static let portScanOptions: [(label: String, seconds: Int)] = [
        ("5s", 5), ("10s", 10), ("30s", 30), ("1m", 60)
    ]

    var portScanLabel: String {
        Self.portScanOptions.first { $0.seconds == portScanIntervalSeconds }?.label ?? "\(portScanIntervalSeconds)s"
    }
    var cleanupIntervalLabel: String {
        Self.intervalOptions.first { $0.seconds == cleanupIntervalSeconds }?.label ?? "\(cleanupIntervalSeconds)s"
    }

    // MARK: - Defaults

    static let defaultPorts = DevCleanupDefaults.ports
    static let defaultAgeThresholdHours = DevCleanupDefaults.ageThresholdHours
    static let defaultPortScanSeconds = DevCleanupDefaults.portScanSeconds
    static let defaultCleanupSeconds = DevCleanupDefaults.cleanupSeconds
    static let defaultRuntimes = DevCleanupDefaults.runtimes
    static let defaultIndicators = DevCleanupDefaults.indicators
    static let defaultExclusions = DevCleanupDefaults.exclusions

    private var portTimer: Timer?
    private var cleanupTimer: Timer?
    private let username = NSUserName()
    private let preferences = DevCleanupPreferences()
    private lazy var service = DevCleanupService.live(username: username)

    /// Serial queue so a port scan and a cleanup pass never run concurrently.
    private let workQueue = DispatchQueue(label: "DevCleanupMonitor.work", qos: .utility)
    /// In-flight guards (touched only on the main thread) so user-configurable
    /// intervals and the manual buttons can't queue up overlapping passes.
    private var isRefreshing = false
    private var isCleaning = false

    init() {
        let settings = preferences.load()
        autoKillEnabled = settings.autoKillEnabled
        ageThresholdHours = settings.ageThresholdHours
        portScanIntervalSeconds = settings.portScanIntervalSeconds
        cleanupIntervalSeconds = settings.cleanupIntervalSeconds
        ports = settings.userPorts
        runtimes = settings.runtimes
        devIndicators = settings.indicators
        exclusions = settings.exclusions
    }

    /// De-duplicate and sort ports so persisted lists yield unique, stable IDs.
    static func normalizedPorts(_ ports: [Int]) -> [Int] {
        DevCleanupPreferences.normalizedPorts(ports)
    }

    /// Trim, lowercase, and de-duplicate string entries (preserving first-seen order)
    /// so persisted lists match the lowercased values detection expects and produce
    /// unique SwiftUI IDs.
    static func normalizedEntries(_ values: [String]) -> [String] {
        DevCleanupPreferences.normalizedEntries(values)
    }

    /// Restore every configurable value to its built-in default.
    func resetToDefaults() {
        preferences.resetToDefaults()
        autoKillEnabled = true
        ageThresholdHours = Self.defaultAgeThresholdHours
        portScanIntervalSeconds = Self.defaultPortScanSeconds
        cleanupIntervalSeconds = Self.defaultCleanupSeconds
        ports = Self.defaultPorts
        runtimes = Self.defaultRuntimes
        devIndicators = Self.defaultIndicators
        exclusions = Self.defaultExclusions
        runCleanup()
    }

    // MARK: - List editing

    /// Add a port (validated 1–65535, de-duplicated, kept sorted).
    func addPort(_ port: Int) {
        guard (1...65535).contains(port), !ports.contains(port) else { return }
        ports = (ports + [port]).sorted()
    }

    func removePort(_ port: Int) { ports.removeAll { $0 == port } }

    /// Add a lowercased, trimmed, de-duplicated entry to one of the string lists.
    func addEntry(_ raw: String, to keyPath: ReferenceWritableKeyPath<DevCleanupMonitor, [String]>) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, !self[keyPath: keyPath].contains(value) else { return }
        self[keyPath: keyPath].append(value)
    }

    func removeEntry(_ value: String, from keyPath: ReferenceWritableKeyPath<DevCleanupMonitor, [String]>) {
        self[keyPath: keyPath].removeAll { $0 == value }
    }

    func start() {
        runCleanup()
        reschedule()
    }

    func stop() {
        portTimer?.invalidate(); portTimer = nil
        cleanupTimer?.invalidate(); cleanupTimer = nil
    }

    /// (Re)create the port-scan and cleanup timers from the current intervals.
    private func reschedule() {
        portTimer?.invalidate()
        cleanupTimer?.invalidate()
        let portInterval = TimeInterval(max(1, portScanIntervalSeconds))
        let cleanupInterval = TimeInterval(max(5, cleanupIntervalSeconds))
        portTimer = Timer.scheduledTimer(withTimeInterval: portInterval, repeats: true) { [weak self] _ in
            self?.refreshPorts()
        }
        portTimer?.tolerance = min(2, portInterval / 5)
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupInterval, repeats: true) { [weak self] _ in
            self?.runCleanup()
        }
        cleanupTimer?.tolerance = min(30, cleanupInterval / 10)
    }

    func killPort(pid: Int32) {
        ProcessSampler.terminate(pid: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPorts()
        }
    }

    /// Refresh only the listening-ports list (no killing).
    func refreshPorts() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let configuration = currentConfiguration()
        workQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.service.scan(configuration: configuration)
                DispatchQueue.main.async {
                    self.portProcesses = result.portProcesses
                    self.isRefreshing = false
                }
            } catch {
                fputs("KillSwitch dev-cleanup scan failed: \(error.localizedDescription)\n", stderr)
                DispatchQueue.main.async {
                    self.isRefreshing = false
                }
            }
        }
    }

    /// Refresh ports and (when enabled) auto-kill long-running dev servers.
    func runCleanup() {
        guard !isCleaning else { return }
        isCleaning = true
        let configuration = currentConfiguration()
        workQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.service.cleanup(configuration: configuration)
                DispatchQueue.main.async {
                    self.portProcesses = result.portProcesses
                    self.candidateCount = result.candidateCount
                    self.cleaned = result.killed
                    self.lastRun = Date()
                    self.isCleaning = false
                }
            } catch {
                fputs("KillSwitch dev-cleanup failed: \(error.localizedDescription)\n", stderr)
                DispatchQueue.main.async {
                    self.isCleaning = false
                }
            }
        }
    }

    private func currentConfiguration() -> DevCleanupConfiguration {
        let integrationPorts = preferences.loadIntegrationPorts()
        return DevCleanupConfiguration(
            autoKillEnabled: autoKillEnabled,
            ageThresholdSeconds: ageThresholdSeconds,
            effectivePorts: DevCleanupPreferences.normalizedPorts(
                ports + integrationPorts.values.flatMap { $0 }
            ),
            runtimes: runtimes,
            indicators: devIndicators,
            exclusions: exclusions
        )
    }
}

// MARK: - View

struct DevCleanupTab: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var monitor = DevCleanupMonitor()
    @State private var portText = ""
    @State private var runtimeText = ""
    @State private var indicatorText = ""
    @State private var exclusionText = ""
    @State private var copiedProcessID: Int32?
    @State private var copyFeedbackRevision = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    portsSection
                    summarySection
                    settingsSection
                    cleanedSection
                }
                .padding(16)
            }
        }
        .background(Theme.background)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .task(id: copyFeedbackRevision) {
            guard copiedProcessID != nil else { return }
            do {
                try await Task.sleep(nanoseconds: 1_600_000_000)
            } catch {
                return
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                copiedProcessID = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "trash")
                .foregroundColor(.orange)
            Text("Dev cleanup")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Button {
                monitor.runCleanup()
            } label: {
                Label("Run cleanup now", systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Summary")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            Text("\(monitor.candidateCount) dev server(s) found · \(monitor.cleaned.count) killed\(monitor.autoKillEnabled ? " (running >\(monitor.ageThresholdHours)h)" : " (auto-kill off)")")
                .font(.system(size: 13))
                .foregroundColor(.white)
            if let last = monitor.lastRun {
                Text("Last cleanup: \(last.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            Text("Protected: Porto Lima hostagents, other users, system, Copilot, MCP servers, IDEs and non-dev apps.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.2)))
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Button { monitor.resetToDefaults() } label: {
                    Label("Reset to defaults", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.white.opacity(0.7))
            }

            HStack(spacing: 16) {
                Toggle(isOn: $monitor.autoKillEnabled) {
                    Text("Auto-kill stale servers")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                }
                .toggleStyle(.switch)
                .tint(.orange)

                labeledPicker("Kill after") {
                    Picker("", selection: $monitor.ageThresholdHours) {
                        ForEach(DevCleanupMonitor.ageOptions, id: \.self) { Text("\($0)h").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 70)
                }
                .disabled(!monitor.autoKillEnabled)
                .opacity(monitor.autoKillEnabled ? 1 : 0.4)
                Spacer()
            }

            HStack(spacing: 16) {
                labeledPicker("Cleanup every") {
                    Picker("", selection: $monitor.cleanupIntervalSeconds) {
                        ForEach(DevCleanupMonitor.intervalOptions, id: \.seconds) { Text($0.label).tag($0.seconds) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 80)
                }
                labeledPicker("Scan ports every") {
                    Picker("", selection: $monitor.portScanIntervalSeconds) {
                        ForEach(DevCleanupMonitor.portScanOptions, id: \.seconds) { Text($0.label).tag($0.seconds) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 70)
                }
                Spacer()
            }

            portsEditor
            listEditor(
                title: "Runtimes", values: monitor.runtimes, placeholder: "e.g. node", text: $runtimeText,
                add: { monitor.addEntry($0, to: \.runtimes) }, remove: { monitor.removeEntry($0, from: \.runtimes) }
            )
            listEditor(
                title: "Dev indicators", values: monitor.devIndicators, placeholder: "e.g. vite", text: $indicatorText,
                add: { monitor.addEntry($0, to: \.devIndicators) }, remove: { monitor.removeEntry($0, from: \.devIndicators) }
            )
            listEditor(
                title: "Protected (never killed)", values: monitor.exclusions, placeholder: "e.g. mcp", text: $exclusionText,
                add: { monitor.addEntry($0, to: \.exclusions) }, remove: { monitor.removeEntry($0, from: \.exclusions) }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.2)))
    }

    private var portsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Ports (\(monitor.ports.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                addField(placeholder: "add port", text: $portText, width: 72) { commitPort() }
            }
            chipFlow(monitor.ports, label: { ":\(String($0))" }) { monitor.removePort($0) }
        }
    }

    /// A reusable "title · add field · chips" editor for one of the string lists.
    private func listEditor(
        title: String,
        values: [String],
        placeholder: String,
        text: Binding<String>,
        add: @escaping (String) -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(title) (\(values.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                addField(placeholder: placeholder, text: text, width: 120) {
                    add(text.wrappedValue); text.wrappedValue = ""
                }
            }
            chipFlow(values, label: { $0 }, onRemove: remove)
        }
    }

    /// A small inline text field plus a "+" button that both commit on submit.
    private func addField(placeholder: String, text: Binding<String>, width: CGFloat, commit: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: width)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                .onSubmit(commit)
            Button(action: commit) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.green.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }

    /// A wrapping grid of removable chips for the given list.
    private func chipFlow<T: Hashable>(_ items: [T], label: @escaping (T) -> String, onRemove: @escaping (T) -> Void) -> some View {
        Group {
            if items.isEmpty {
                Text("None")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 4) {
                            Text(label(item))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                            Button { onRemove(item) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .fixedSize()
                    }
                }
            }
        }
    }

    private func labeledPicker<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            content()
        }
    }

    private func commitPort() {
        if let port = Int(portText.trimmingCharacters(in: .whitespaces)) {
            monitor.addPort(port)
        }
        portText = ""
    }

    private var portsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Running dev servers & notable ports (\(monitor.portProcesses.count))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            if monitor.portProcesses.isEmpty {
                Text("Nothing listening on tracked ports.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ForEach(monitor.portProcesses) { proc in
                    let isCopied = copiedProcessID == proc.pid
                    HStack(spacing: 12) {
                        Text(":\(String(proc.port))")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.green.opacity(0.8))
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(proc.command)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Text("PID: \(String(proc.pid))")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        Spacer()
                        Button {
                            copyCommand(proc.command, from: proc.pid)
                        } label: {
                            Label(
                                isCopied ? "Copied" : "Copy",
                                systemImage: isCopied ? "checkmark.circle.fill" : "doc.on.doc"
                            )
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 70, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(isCopied ? .green.opacity(0.9) : .white.opacity(0.7))
                        .help(isCopied ? "Command copied" : "Copy full command")
                        .accessibilityLabel(isCopied ? "Command copied" : "Copy full command")
                        if let reason = ProcessTerminationPolicy.protectionReason(for: proc.command) {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.white.opacity(0.45))
                                .help(reason)
                                .accessibilityLabel("Protected process")
                        } else {
                            KillButton(pid: proc.pid) { monitor.killPort(pid: proc.pid) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                }
            }
        }
    }

    private func copyCommand(_ command: String, from pid: Int32) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(command, forType: .string) else {
            fputs("KillSwitch could not copy the dev server command to the clipboard.\n", stderr)
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            copiedProcessID = pid
        }
        copyFeedbackRevision += 1
    }

    private var cleanedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Auto-killed dev servers (\(monitor.cleaned.count))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            if monitor.cleaned.isEmpty {
                Text("No long-running dev servers cleaned up.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ForEach(monitor.cleaned) { proc in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(proc.runtime.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.orange)
                            Text(String(format: "%.1fh", proc.ageHours))
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                            Text("PID \(String(proc.pid))")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        Text(proc.command)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
                }
            }
        }
    }
}
