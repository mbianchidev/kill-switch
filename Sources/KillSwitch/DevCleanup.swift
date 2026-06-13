import SwiftUI

/// A process listening on a notable development port.
struct PortProcess: Identifiable {
    let id: String
    let pid: Int32
    let command: String
    let port: Int
}

/// A dev server that was auto-terminated by the cleanup.
struct CleanedProcess: Identifiable {
    let id: Int32
    let pid: Int32
    let command: String
    let runtime: String
    let ageHours: Double
}

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
        didSet { Defaults.set(autoKillEnabled, .autoKill) }
    }
    /// Age (in hours) a dev server must exceed before it is auto-killed.
    @Published var ageThresholdHours: Int {
        didSet { Defaults.set(ageThresholdHours, .ageHours) }
    }
    /// How often (seconds) the listening-ports list is refreshed.
    @Published var portScanIntervalSeconds: Int {
        didSet { Defaults.set(portScanIntervalSeconds, .portInterval); reschedule() }
    }
    /// How often (seconds) the auto-cleanup pass runs.
    @Published var cleanupIntervalSeconds: Int {
        didSet { Defaults.set(cleanupIntervalSeconds, .cleanupInterval); reschedule() }
    }
    /// The watched dev ports. A process listening on any of these is always listed.
    @Published var ports: [Int] {
        didSet { Defaults.set(ports, .ports) }
    }
    /// Runtime binaries that indicate a dev server (matched on the executable name).
    @Published var runtimes: [String] {
        didSet { Defaults.set(runtimes, .runtimes) }
    }
    /// Command-line signatures that mark a process as an actual dev server.
    @Published var devIndicators: [String] {
        didSet { Defaults.set(devIndicators, .indicators) }
    }
    /// Substrings that protect a process from being auto-killed.
    @Published var exclusions: [String] {
        didSet { Defaults.set(exclusions, .exclusions) }
    }

    var ageThresholdSeconds: Int { ageThresholdHours * 3600 }

    /// Picker options shared with the UI.
    static let intervalOptions = TopConsumersMonitor.intervalOptions
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

    /// The explicitly requested ports plus a few similar, common dev ports.
    static let defaultPorts: [Int] = [
        3000, 3001, 3002, 3003, 4000, 4200, 5000, 5001, 5173, 5174, 5555,
        6006, 8000, 8001, 8080, 8081, 8090, 8443, 8888, 9000, 9090, 9091
    ].sorted()

    static let defaultAgeThresholdHours = 12
    static let defaultPortScanSeconds = 5
    static let defaultCleanupSeconds = 600

    static let defaultRuntimes: [String] = [
        "node", "deno", "bun",
        "npm", "npx", "pnpm", "yarn",
        "python", "python3", "python2",
        "java", "mvn",
        "cargo", "rustc",
        "go", "ruby"
    ]

    static let defaultIndicators: [String] = [
        "vite", "next dev", "nodemon", "webpack", "react-scripts", "ng serve",
        "astro dev", "nuxt", "remix", "ng build --watch", "electron .", "electron-forge",
        "npm run", "npm start", "npm exec", "npx", "yarn dev", "yarn start",
        "pnpm dev", "pnpm start", "pnpm run", "bun run", "bun dev",
        "spring-boot:run", "gradlew", "quarkus:dev",
        "cargo run", "cargo watch", "cargo-watch", "trunk serve",
        "go run", "air",
        "rails server", "rails s", "puma", "rackup",
        "flask run", "uvicorn", "gunicorn", "manage.py runserver", "runserver",
        "http.server", "deno run", "deno task"
    ]

    /// Substrings that protect a process from being auto-killed. Bias toward
    /// NOT killing: matching any of these skips the process entirely.
    static let defaultExclusions: [String] = [
        "copilot",
        "mcp", "modelcontextprotocol", "context7", "work_iq", "work-iq", "workiq",
        "fabric", "seismic", "azure", "kusto", "revenue", "server-github",
        "killswitch", "visual studio code", "code helper", "electron", "obsidian",
        "chrome", "slack", "teams", "orbstack", "spotify", "handy",
        "language-server", "language_server", "tsserver", "lsp"
    ]

    private var portTimer: Timer?
    private var cleanupTimer: Timer?
    private let username = NSUserName()

    init() {
        autoKillEnabled = Defaults.bool(.autoKill, default: true)
        ageThresholdHours = Defaults.int(.ageHours, default: Self.defaultAgeThresholdHours)
        portScanIntervalSeconds = Defaults.int(.portInterval, default: Self.defaultPortScanSeconds)
        cleanupIntervalSeconds = Defaults.int(.cleanupInterval, default: Self.defaultCleanupSeconds)
        ports = Defaults.ints(.ports, default: Self.defaultPorts)
        runtimes = Defaults.strings(.runtimes, default: Self.defaultRuntimes)
        devIndicators = Defaults.strings(.indicators, default: Self.defaultIndicators)
        exclusions = Defaults.strings(.exclusions, default: Self.defaultExclusions)
    }

    /// Restore every configurable value to its built-in default.
    func resetToDefaults() {
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
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupInterval, repeats: true) { [weak self] _ in
            self?.runCleanup()
        }
    }

    func killPort(pid: Int32) {
        ProcessSampler.terminate(pid: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPorts()
        }
    }

    /// Refresh only the listening-ports list (no killing).
    func refreshPorts() {
        let ports = self.ports
        let runtimes = self.runtimes
        let indicators = self.devIndicators
        let exclusions = self.exclusions
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let detailed = ProcessSampler.fetchDetailed()
            let commandByPid = Dictionary(detailed.map { ($0.pid, $0.command) }, uniquingKeysWith: { a, _ in a })
            let listening = ProcessSampler.listeningPorts()
            let rows = Self.portRows(
                commandByPid: commandByPid, ports: listening,
                notablePorts: Set(ports), runtimes: runtimes, indicators: indicators, exclusions: exclusions
            )
            DispatchQueue.main.async { self.portProcesses = rows }
        }
    }

    /// Refresh ports and (when enabled) auto-kill long-running dev servers.
    func runCleanup() {
        let ports = self.ports
        let runtimes = self.runtimes
        let indicators = self.devIndicators
        let exclusions = self.exclusions
        let autoKill = self.autoKillEnabled
        let ageThreshold = self.ageThresholdSeconds
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let detailed = ProcessSampler.fetchDetailed()
            let commandByPid = Dictionary(detailed.map { ($0.pid, $0.command) }, uniquingKeysWith: { a, _ in a })
            let listening = ProcessSampler.listeningPorts()
            let portRows = Self.portRows(
                commandByPid: commandByPid, ports: listening,
                notablePorts: Set(ports), runtimes: runtimes, indicators: indicators, exclusions: exclusions
            )

            var candidates = 0
            var killed: [CleanedProcess] = []
            for proc in detailed where proc.user == self.username {
                guard let runtime = Self.devRuntime(proc.command, runtimes: runtimes),
                      Self.isDevServer(proc.command, indicators: indicators),
                      !Self.isSystemProcess(proc.command),
                      !Self.isExcluded(proc.command, exclusions: exclusions) else { continue }
                candidates += 1
                if autoKill, proc.etimeSeconds > ageThreshold {
                    if ProcessSampler.terminate(pid: proc.pid) {
                        killed.append(
                            CleanedProcess(
                                id: proc.pid,
                                pid: proc.pid,
                                command: proc.command,
                                runtime: runtime,
                                ageHours: Double(proc.etimeSeconds) / 3600.0
                            )
                        )
                    }
                }
            }

            DispatchQueue.main.async {
                self.portProcesses = portRows
                self.candidateCount = candidates
                self.cleaned = killed
                self.lastRun = Date()
            }
        }
    }

    /// Build the listening-ports rows: every process on a notable port, plus any
    /// recognized dev server (incl. npm) regardless of which port it binds to.
    private static func portRows(
        commandByPid: [Int32: String],
        ports: [Int32: Set<Int>],
        notablePorts: Set<Int>,
        runtimes: [String],
        indicators: [String],
        exclusions: [String]
    ) -> [PortProcess] {
        var rows: [PortProcess] = []
        for (pid, portSet) in ports {
            let command = commandByPid[pid] ?? "pid \(pid)"
            if isSystemProcess(command) { continue }
            let isDev = devRuntime(command, runtimes: runtimes) != nil
                && isDevServer(command, indicators: indicators)
                && !isExcluded(command, exclusions: exclusions)
            for port in portSet where notablePorts.contains(port) || isDev {
                rows.append(PortProcess(id: "\(pid)-\(port)", pid: pid, command: command, port: port))
            }
        }
        rows.sort { $0.port == $1.port ? $0.pid < $1.pid : $0.port < $1.port }
        return rows
    }

    // MARK: - Classification

    private static func isExcluded(_ command: String, exclusions: [String]) -> Bool {
        let lower = command.lowercased()
        return exclusions.contains { lower.contains($0) }
    }

    /// Never kill anything launched from /System/ (macOS system binaries).
    private static func isSystemProcess(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/System/")
    }

    private static func isDevServer(_ command: String, indicators: [String]) -> Bool {
        let lower = command.lowercased()
        return indicators.contains { lower.contains($0) }
    }

    /// Returns the runtime name if the command's executable is a known runtime.
    private static func devRuntime(_ command: String, runtimes: [String]) -> String? {
        guard let firstToken = command.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let exe = firstToken.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        return runtimes.first { exe == $0 || exe.hasPrefix($0) }
    }
}

/// Tiny typed wrapper over `UserDefaults` for the dev-cleanup settings.
private enum Defaults {
    enum Key: String {
        case autoKill = "devcleanup.autoKill"
        case ageHours = "devcleanup.ageHours"
        case portInterval = "devcleanup.portInterval"
        case cleanupInterval = "devcleanup.cleanupInterval"
        case ports = "devcleanup.ports"
        case runtimes = "devcleanup.runtimes"
        case indicators = "devcleanup.indicators"
        case exclusions = "devcleanup.exclusions"
    }

    static func set(_ value: Bool, _ key: Key) { UserDefaults.standard.set(value, forKey: key.rawValue) }
    static func set(_ value: Int, _ key: Key) { UserDefaults.standard.set(value, forKey: key.rawValue) }
    static func set(_ value: [Int], _ key: Key) { UserDefaults.standard.set(value, forKey: key.rawValue) }
    static func set(_ value: [String], _ key: Key) { UserDefaults.standard.set(value, forKey: key.rawValue) }

    static func bool(_ key: Key, default fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key.rawValue) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key.rawValue)
    }
    static func int(_ key: Key, default fallback: Int) -> Int {
        guard UserDefaults.standard.object(forKey: key.rawValue) != nil else { return fallback }
        return UserDefaults.standard.integer(forKey: key.rawValue)
    }
    static func ints(_ key: Key, default fallback: [Int]) -> [Int] {
        guard let values = UserDefaults.standard.array(forKey: key.rawValue) else { return fallback }
        let converted = values.compactMap { value -> Int? in
            if let int = value as? Int { return int }
            if let number = value as? NSNumber { return number.intValue }
            return nil
        }
        return converted.count == values.count ? converted : fallback
    }
    static func strings(_ key: Key, default fallback: [String]) -> [String] {
        guard let values = UserDefaults.standard.array(forKey: key.rawValue) else { return fallback }
        let converted = values.compactMap { $0 as? String }
        return converted.count == values.count ? converted : fallback
    }
}

// MARK: - View

struct DevCleanupTab: View {
    @StateObject private var monitor = DevCleanupMonitor()
    @State private var portText = ""
    @State private var runtimeText = ""
    @State private var indicatorText = ""
    @State private var exclusionText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summarySection
                    settingsSection
                    portsSection
                    cleanedSection
                }
                .padding(16)
            }
        }
        .background(Theme.background)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
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
            Text("Protected: other users, system, Copilot, MCP servers, IDEs and non-dev apps.")
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
            chipFlow(monitor.ports, label: { ":\($0)" }) { monitor.removePort($0) }
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
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 64, maximum: 220), spacing: 6, alignment: .leading)],
                    alignment: .leading, spacing: 6
                ) {
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 4) {
                            Text(label(item))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.middle)
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
            Text("Dev servers & notable ports (\(monitor.portProcesses.count))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            if monitor.portProcesses.isEmpty {
                Text("Nothing listening on tracked ports.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ForEach(monitor.portProcesses) { proc in
                    HStack(spacing: 12) {
                        Text(":\(proc.port)")
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
                        KillButton(pid: proc.pid) { monitor.killPort(pid: proc.pid) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                }
            }
        }
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
