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
final class DevCleanupMonitor: ObservableObject {
    @Published var portProcesses: [PortProcess] = []
    @Published var cleaned: [CleanedProcess] = []
    @Published var candidateCount: Int = 0
    @Published var lastRun: Date?

    private var portTimer: Timer?
    private var cleanupTimer: Timer?
    private let username = NSUserName()

    /// The explicitly requested ports plus a few similar, common dev ports.
    static let notablePorts: Set<Int> = [
        3000, 3001, 3003, 5173, 5174, 8000, 8080, 8888, 9000, 9090, // requested
        3002, 4000, 4200, 5000, 5001, 5555, 6006, 8001, 8081, 8090, 8443, 9091 // similar
    ]

    private static let ageThresholdSeconds = 12 * 3600

    /// Runtime binaries that indicate a dev server (matched on the executable name).
    private static let runtimes: [String] = [
        "node", "deno", "bun",
        "npm", "npx", "pnpm", "yarn",
        "python", "python3", "python2",
        "java", "mvn",
        "cargo", "rustc",
        "go", "ruby"
    ]

    /// Command-line signatures that mark a process as an actual dev server.
    private static let devIndicators: [String] = [
        "vite", "next dev", "nodemon", "webpack", "react-scripts", "ng serve",
        "astro dev", "nuxt", "remix", "ng build --watch", "electron .", "electron-forge",
        "npm run", "npm start", "npm exec", "npx", "yarn dev", "yarn start",
        "pnpm dev", "pnpm start", "pnpm run", "bun run", "bun dev",
        "spring-boot:run", "gradlew", "quarkus:dev",
        "cargo run", "cargo watch", "cargo-watch", "trunk serve",
        "go run", "air", // air = go live-reload
        "rails server", "rails s", "puma", "rackup",
        "flask run", "uvicorn", "gunicorn", "manage.py runserver", "runserver",
        "http.server", "deno run", "deno task"
    ]

    /// Substrings that protect a process from being auto-killed. Bias toward
    /// NOT killing: matching any of these skips the process entirely.
    private static let exclusions: [String] = [
        "copilot",
        // MCP servers
        "mcp", "modelcontextprotocol", "context7", "work_iq", "work-iq", "workiq",
        "fabric", "seismic", "azure", "kusto", "revenue", "server-github",
        // IDEs / editors / apps
        "killswitch", "visual studio code", "code helper", "electron", "obsidian",
        "chrome", "slack", "teams", "orbstack", "spotify", "handy",
        "language-server", "language_server", "tsserver", "lsp"
    ]

    func start() {
        runCleanup()
        portTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshPorts()
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 600.0, repeats: true) { [weak self] _ in
            self?.runCleanup()
        }
    }

    func stop() {
        portTimer?.invalidate(); portTimer = nil
        cleanupTimer?.invalidate(); cleanupTimer = nil
    }

    func killPort(pid: Int32) {
        ProcessSampler.terminate(pid: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPorts()
        }
    }

    /// Refresh only the listening-ports list (no killing).
    func refreshPorts() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let detailed = ProcessSampler.fetchDetailed()
            let commandByPid = Dictionary(detailed.map { ($0.pid, $0.command) }, uniquingKeysWith: { a, _ in a })
            let ports = ProcessSampler.listeningPorts()
            let rows = Self.portRows(commandByPid: commandByPid, ports: ports)
            DispatchQueue.main.async { self.portProcesses = rows }
        }
    }

    /// Refresh ports and auto-kill long-running dev servers.
    func runCleanup() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let detailed = ProcessSampler.fetchDetailed()
            let commandByPid = Dictionary(detailed.map { ($0.pid, $0.command) }, uniquingKeysWith: { a, _ in a })
            let ports = ProcessSampler.listeningPorts()
            let portRows = Self.portRows(commandByPid: commandByPid, ports: ports)

            var candidates = 0
            var killed: [CleanedProcess] = []
            for proc in detailed where proc.user == self.username {
                guard let runtime = Self.devRuntime(proc.command),
                      Self.isDevServer(proc.command),
                      !Self.isSystemProcess(proc.command),
                      !Self.isExcluded(proc.command) else { continue }
                candidates += 1
                if proc.etimeSeconds > Self.ageThresholdSeconds {
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
    private static func portRows(commandByPid: [Int32: String], ports: [Int32: Set<Int>]) -> [PortProcess] {
        var rows: [PortProcess] = []
        for (pid, portSet) in ports {
            let command = commandByPid[pid] ?? "pid \(pid)"
            if isSystemProcess(command) { continue }
            let isDev = devRuntime(command) != nil && isDevServer(command) && !isExcluded(command)
            for port in portSet where notablePorts.contains(port) || isDev {
                rows.append(PortProcess(id: "\(pid)-\(port)", pid: pid, command: command, port: port))
            }
        }
        rows.sort { $0.port == $1.port ? $0.pid < $1.pid : $0.port < $1.port }
        return rows
    }

    // MARK: - Classification

    private static func isExcluded(_ command: String) -> Bool {
        let lower = command.lowercased()
        return exclusions.contains { lower.contains($0) }
    }

    /// Never kill anything launched from /System/ (macOS system binaries).
    private static func isSystemProcess(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/System/")
    }

    private static func isDevServer(_ command: String) -> Bool {
        let lower = command.lowercased()
        return devIndicators.contains { lower.contains($0) }
    }

    /// Returns the runtime name if the command's executable is a known runtime.
    private static func devRuntime(_ command: String) -> String? {
        guard let firstToken = command.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let exe = firstToken.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        return runtimes.first { exe == $0 || exe.hasPrefix($0) }
    }
}

// MARK: - View

struct DevCleanupTab: View {
    @StateObject private var monitor = DevCleanupMonitor()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summarySection
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
            Text("\(monitor.candidateCount) dev server(s) found · \(monitor.cleaned.count) killed (running >12h)")
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
