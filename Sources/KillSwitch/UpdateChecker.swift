import Foundation
import AppKit
import SwiftUI
import CryptoKit

// MARK: - Models

/// A published GitHub release the app could update to.
struct ReleaseInfo: Equatable {
    let version: String   // tag_name, e.g. "v1.1.2"
    let name: String
    let notes: String
    let binaryURL: URL    // browser_download_url of the raw "KillSwitch" asset
    let checksumURL: URL? // browser_download_url of the "KillSwitch.sha256" asset
}

/// Errors surfaced by the update flow. All are user-presentable.
enum UpdateError: LocalizedError {
    case network(String)
    case decoding(String)
    case noRelease
    case noAsset
    case download(String)
    case invalidBinary
    case checksumMismatch
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .network(let m):     return "Network error: \(m)"
        case .decoding(let m):    return "Could not read release info: \(m)"
        case .noRelease:          return "No published release found."
        case .noAsset:            return "Latest release has no KillSwitch binary attached."
        case .download(let m):    return "Download failed: \(m)"
        case .invalidBinary:      return "Downloaded file is not a valid macOS executable."
        case .checksumMismatch:   return "Downloaded binary failed checksum verification."
        case .installFailed(let m): return "Install failed: \(m)"
        }
    }
}

/// State machine driving the update UI.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(ReleaseInfo)
    case downloading
    case installing
    case failed(String)
}

// MARK: - UpdateChecker

/// Checks the GitHub Releases API for a newer build, and (when the user asks)
/// downloads the new binary and installs it over the user-owned
/// `~/bin/KillSwitch`. The install path is user-writable, so no privilege
/// escalation (admin password) is required.
///
/// Designed to be self-contained: the rest of the app only needs
/// `UpdateChecker.shared` and `checkForUpdates()`.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var latest: ReleaseInfo?
    @Published private(set) var lastChecked: Date?
    @Published var bannerDismissed = false

    let currentVersion = AppVersion.current

    private let releasesURL = URL(string: "https://api.github.com/repos/mbianchidev/kill-switch/releases/latest")!
    private let installPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("bin/KillSwitch").path
    private let assetName = "KillSwitch"
    private let checksumAssetName = "KillSwitch.sha256"
    private let agentPlistPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/io.killswitch.agent.plist").path
    private static let logURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/killswitch-update.log")

    private var periodicTimer: Timer?

    var availableRelease: ReleaseInfo? {
        if case .available(let r) = state { return r }
        return nil
    }

    private init() {}

    // MARK: Public entry points

    /// Fire-and-forget update check. Safe to call from any thread / the UI.
    func checkForUpdates() {
        Task { await check() }
    }

    /// Begin checking on launch and every 6 hours thereafter.
    func startPeriodicChecks(interval: TimeInterval = 6 * 60 * 60) {
        checkForUpdates()
        DispatchQueue.main.async {
            self.periodicTimer?.invalidate()
            self.periodicTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.checkForUpdates()
            }
        }
    }

    /// Download the available release's binary and install it. No-op unless an
    /// update is currently available.
    func install() {
        Task { await downloadAndInstall() }
    }

    // MARK: Check

    @MainActor
    private func check() async {
        if case .downloading = state { return }
        if case .installing = state { return }
        setState(.checking)

        var req = URLRequest(url: releasesURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("KillSwitch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateError.network("no HTTP response")
            }
            guard http.statusCode == 200 else {
                throw UpdateError.network("GitHub API returned \(http.statusCode)")
            }
            let release = try parse(data)
            lastChecked = Date()
            latest = release
            if Self.isNewer(release.version, than: currentVersion) {
                log("Update available: \(release.version) (current \(currentVersion))")
                setState(.available(release))
            } else {
                log("Up to date (current \(currentVersion), latest \(release.version))")
                setState(.upToDate)
            }
        } catch {
            let message = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
            log("Check failed: \(message)")
            setState(.failed(message))
        }
    }

    private func parse(_ data: Data) throws -> ReleaseInfo {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UpdateError.decoding("malformed JSON")
        }
        guard let tag = obj["tag_name"] as? String, !tag.isEmpty else {
            throw UpdateError.noRelease
        }
        let name = (obj["name"] as? String) ?? tag
        let notes = (obj["body"] as? String) ?? ""
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
              let urlStr = asset["browser_download_url"] as? String,
              let url = URL(string: urlStr) else {
            throw UpdateError.noAsset
        }
        let checksumURL = assets
            .first(where: { ($0["name"] as? String) == checksumAssetName })
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap { URL(string: $0) }
        return ReleaseInfo(version: tag, name: name, notes: notes, binaryURL: url, checksumURL: checksumURL)
    }

    // MARK: Install

    @MainActor
    private func downloadAndInstall() async {
        guard case .available(let release) = state else { return }
        setState(.downloading)
        do {
            let tmp = try await download(release.binaryURL)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try validate(tmp)
            try await verifyChecksum(of: tmp, release: release)
            setState(.installing)
            try installBinary(from: tmp)
            log("Installed \(release.version); relaunching")
            relaunch()
        } catch {
            let message = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
            log("Install failed: \(message)")
            setState(.failed(message))
        }
    }

    private func download(_ url: URL) async throws -> URL {
        var req = URLRequest(url: url)
        req.setValue("KillSwitch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 120
        do {
            let (tempURL, response) = try await URLSession.shared.download(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.download("HTTP \(http.statusCode)")
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("KillSwitch-update-\(UUID().uuidString)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            return dest
        } catch let e as UpdateError {
            throw e
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
    }

    /// Reject anything that isn't a plausibly-sized Mach-O executable before we
    /// hand it to a privileged copy.
    private func validate(_ url: URL) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size >= 4096 else { throw UpdateError.invalidBinary }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw UpdateError.invalidBinary
        }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        guard magic.count == 4 else { throw UpdateError.invalidBinary }

        let value = magic.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let machO: Set<UInt32> = [0xFEEDFACE, 0xFEEDFACF, 0xCAFEBABE, 0xCAFEBABF]
        guard machO.contains(value) || machO.contains(value.byteSwapped) else {
            throw UpdateError.invalidBinary
        }
    }

    /// Verify the downloaded binary against the SHA-256 published alongside the
    /// release. This is an integrity/authenticity gate: without it a tampered
    /// asset (or compromised release) could be installed as root. Fails closed —
    /// a missing or mismatched checksum aborts the install.
    private func verifyChecksum(of url: URL, release: ReleaseInfo) async throws {
        guard let checksumURL = release.checksumURL else {
            throw UpdateError.checksumMismatch
        }
        let checksumFile = try await download(checksumURL)
        defer { try? FileManager.default.removeItem(at: checksumFile) }

        guard let raw = try? String(contentsOf: checksumFile, encoding: .utf8) else {
            throw UpdateError.checksumMismatch
        }
        // Accept both bare digests and `<digest>  <filename>` (shasum) formats.
        guard let expected = raw
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .first
            .map({ $0.lowercased() }),
            expected.count == 64,
            expected.allSatisfy({ $0.isHexDigit }) else {
            throw UpdateError.checksumMismatch
        }

        guard let data = try? Data(contentsOf: url) else {
            throw UpdateError.checksumMismatch
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            log("Checksum mismatch: expected \(expected), got \(actual)")
            throw UpdateError.checksumMismatch
        }
    }

    /// Copy the validated binary into the user-owned install path (`~/bin`) and
    /// mark it executable. No privilege escalation is needed — the path lives in
    /// the user's home directory, so the LaunchAgent that runs it and the updater
    /// that writes it always agree.
    private func installBinary(from src: URL) throws {
        let fm = FileManager.default
        let dir = (installPath as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: installPath) {
                try fm.removeItem(atPath: installPath)
            }
            try fm.copyItem(atPath: src.path, toPath: installPath)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installPath)
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }

    /// Reload the LaunchAgent (which relaunches a fresh instance) and quit. If no
    /// agent is installed, launch the new binary directly.
    private func relaunch() {
        let script: String
        if FileManager.default.fileExists(atPath: agentPlistPath) {
            script = "sleep 1; launchctl unload \(Self.shQuote(agentPlistPath)) 2>/dev/null; "
                + "launchctl load \(Self.shQuote(agentPlistPath)) 2>/dev/null"
        } else {
            script = "sleep 1; \(Self.shQuote(installPath)) >/dev/null 2>&1 &"
        }
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", script]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    // MARK: Version comparison

    /// Compare dotted semver strings component-wise (e.g. `v1.1.2`), ignoring a
    /// leading `v`. A `dev` build parses to 0 and is always considered older, so
    /// any published release shows as an update.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func components(_ v: String) -> [Int] {
            v.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "v "))
                .split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = components(candidate)
        let b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Helpers

    private func setState(_ newState: UpdateState) {
        if Thread.isMainThread {
            state = newState
        } else {
            DispatchQueue.main.async { self.state = newState }
        }
    }

    /// POSIX single-quote a string for safe shell interpolation.
    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Best-effort logging to stdout and `~/Library/Logs/killswitch-update.log`.
    /// Never throws: logging must not break the app.
    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) [UpdateChecker] \(message)\n"
        print(line, terminator: "")
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: Self.logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: Self.logURL)
            }
        }
    }
}

// MARK: - Banner

/// Slim banner shown at the top of the window when a newer release exists.
/// Renders nothing when there's no update or the user dismissed it.
struct UpdateBanner: View {
    @ObservedObject var updater: UpdateChecker

    var body: some View {
        if let release = updater.availableRelease, !updater.bannerDismissed {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.green)
                Text("Update available: \(release.version)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text("(you have \(updater.currentVersion))")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Button("Install") { updater.install() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button {
                    updater.bannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.6))
                .help("Dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.18))
        }
    }
}

// MARK: - Updates tab

struct UpdatesTab: View {
    @ObservedObject var updater: UpdateChecker

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    versionSection
                    statusSection
                }
                .padding(16)
            }
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(.green)
            Text("Updates")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Button { updater.checkForUpdates() } label: {
                Label("Check for updates", systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.white.opacity(0.8))
            .disabled(isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Current version", updater.currentVersion)
            if let latest = updater.latest {
                row("Latest release", latest.version)
            }
            if let checked = updater.lastChecked {
                row("Last checked", checked.formatted(date: .abbreviated, time: .standard))
            }
            if updater.currentVersion == "dev" {
                Text("Running an unreleased local build — any published release will show as an update.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.2)))
    }

    @ViewBuilder
    private var statusSection: some View {
        switch updater.state {
        case .idle:
            statusLine(icon: "circle", color: .gray, text: "Idle.")
        case .checking:
            statusLine(icon: "arrow.clockwise", color: .blue, text: "Checking for updates…")
        case .upToDate:
            statusLine(icon: "checkmark.circle.fill", color: .green, text: "You're on the latest version.")
        case .available(let release):
            availableView(release)
        case .downloading:
            statusLine(icon: "arrow.down.circle", color: .blue, text: "Downloading update…")
        case .installing:
            statusLine(icon: "gearshape", color: .blue, text: "Installing (admin password required)…")
        case .failed(let message):
            statusLine(icon: "exclamationmark.triangle.fill", color: .orange, text: message)
        }
    }

    private func availableView(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine(icon: "arrow.down.circle.fill", color: .green,
                       text: "Version \(release.version) is available.")
            if !release.notes.isEmpty {
                Text(release.notes)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
            }
            Button { updater.install() } label: {
                Label("Download & install", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            Text("Installs over /usr/local/bin/KillSwitch and relaunches. You'll be asked for your password.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
    }

    private func statusLine(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(color)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    private var isBusy: Bool {
        switch updater.state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }
}
