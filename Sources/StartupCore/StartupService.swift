import Foundation
import InstallCore

public struct StartupSnapshot {
    public let items: [StartupItem]
    public let warnings: [String]
}

public final class StartupService {
    private let home: URL
    private let currentUID: UInt32
    private let stateDirectory: URL
    private let runner: StartupCommandRunning
    private let manager = FileManager.default
    private var cachedSystemCron: [StartupItem] = []
    private var cachedBackgroundItems: [StartupItem] = []

    public init(home: URL, currentUID: UInt32, stateDirectory: URL, runner: StartupCommandRunning = NativeStartupCommandRunner()) {
        self.home = home
        self.currentUID = currentUID
        self.stateDirectory = stateDirectory
        self.runner = runner
    }

    public func scan(
        includeLoginApps: Bool = false, includeSystemCron: Bool = false, includeBackgroundItems: Bool = false
    ) -> StartupSnapshot {
        var items: [StartupItem] = []
        var warnings: [String] = []
        let locations: [(URL, StartupDomain)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .gui(currentUID)),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .gui(currentUID)),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .system),
            (URL(fileURLWithPath: "/System/Library/LaunchAgents"), .gui(currentUID)),
            (URL(fileURLWithPath: "/System/Library/LaunchDaemons"), .system)
        ]
        var overrides: [String: [String: Bool]] = [:]
        for domain in [StartupDomain.gui(currentUID), .system] {
            do {
                let result = try checked(StartupCommandPlanner.serviceOverrides(domain))
                overrides[domain.target] = try StartupParsers.disabledServices(result.output)
            } catch { warnings.append("\(domain.label) services: \(error.localizedDescription)") }
        }
        for (directory, domain) in locations {
            guard manager.fileExists(atPath: directory.path) else { continue }
            do {
                for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path })
                where url.pathExtension == "plist" {
                    do {
                        let item = try readLaunchService(at: url, domain: domain, overrides: overrides[domain.target])
                        if let index = items.firstIndex(where: { $0.id == item.id }) {
                            items[index].restriction = "Multiple startup files use this service label. Manage it manually."
                            warnings.append("Duplicate service label: \(item.name)")
                        } else { items.append(item) }
                    } catch { warnings.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
            } catch { warnings.append("\(directory.path): \(error.localizedDescription)") }
        }

        do { items += try cronItems(domain: .gui(currentUID)) }
        catch { warnings.append("My account cron: \(error.localizedDescription)") }
        if includeSystemCron {
            do { cachedSystemCron = try cronItems(domain: .system) }
            catch { warnings.append("System cron refresh failed; showing any cached entries: \(error.localizedDescription)") }
        }
        items += cachedSystemCron
        do {
            let saved = try readDisabledLoginItems()
            var live: [LegacyLoginItem]?
            if includeLoginApps {
                do { live = try readLoginItems() }
                catch { warnings.append("Login apps: \(error.localizedDescription)") }
            }
            items += StartupParsers.loginItems(saved: saved, live: live, currentUID: currentUID)
        } catch { warnings.append("Login apps: \(error.localizedDescription)") }

        if includeBackgroundItems {
            do { cachedBackgroundItems = try readBackgroundItems() }
            catch { warnings.append("Background-item refresh failed; showing any cached entries: \(error.localizedDescription)") }
        }
        items += cachedBackgroundItems
        return StartupSnapshot(items: items, warnings: warnings)
    }

    public func readBackgroundItems() throws -> [StartupItem] {
        let output = try checked(StartupCommand(
            "/usr/bin/sfltool", arguments: ["dumpbtm"], administrator: true
        )).output
        let items = StartupParsers.backgroundItems(output, currentUID: currentUID)
        if items.isEmpty && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw StartupError("macOS background-item data could not be decoded. Use Login Items in System Settings.")
        }
        return items
    }

    public func readLaunchService(
        at url: URL, domain: StartupDomain, overrides: [String: Bool]?
    ) throws -> StartupItem {
        let roots: [URL]
        switch domain {
        case let .gui(uid):
            guard uid == currentUID else { throw StartupError("Other users' services are read-only.") }
            roots = [
                home.appendingPathComponent("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"),
                URL(fileURLWithPath: "/System/Library/LaunchAgents")
            ]
        case .system:
            roots = [URL(fileURLWithPath: "/Library/LaunchDaemons"), URL(fileURLWithPath: "/System/Library/LaunchDaemons")]
        }
        guard roots.contains(where: { $0.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL }) else {
            throw StartupError("This file is outside the supported startup directories.")
        }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        let parent = try manager.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              parent[.type] as? FileAttributeType == .typeDirectory else {
            throw StartupError("Linked or non-file startup entries are read-only.")
        }
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String else {
            throw StartupError("This startup file does not have a readable service label.")
        }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let program = plist["Program"] as? String ?? arguments.first ?? ""
        let service = LaunchService(
            label: label, url: url, domain: domain, program: program, fingerprint: startupFingerprint(data)
        )
        var restriction: String?
        do { _ = try StartupCommandPlanner.launchService(service, enabled: false, currentUID: currentUID) }
        catch { restriction = error.localizedDescription }
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let isHomeFile = url.path.hasPrefix(home.appendingPathComponent("Library/LaunchAgents").path + "/")
        if owner != (isHomeFile ? currentUID : 0) {
            restriction = "This startup file has unexpected ownership and is read-only."
        }
        if overrides == nil { restriction = restriction ?? "Startup state could not be verified. Refresh before changing this entry." }
        let disabled = overrides?[label] ?? (plist["Disabled"] as? Bool ?? false)
        return StartupItem(
            id: "service/\(domain.target)/\(label)", name: label,
            kind: domain == .system ? .daemon : .agent, domain: domain,
            command: arguments.isEmpty ? program : arguments.joined(separator: " "), origin: url.path,
            state: overrides == nil ? .unknown : (disabled ? .disabled : .enabled),
            restriction: restriction, source: .launchService(service)
        )
    }

    public func setEnabled(_ enabled: Bool, item: StartupItem) throws {
        guard item.restriction == nil, item.state != .unknown else {
            throw StartupError(item.restriction ?? "This entry's startup state is unknown. Refresh first.")
        }
        switch item.source {
        case let .launchService(service):
            let current = try readLaunchService(at: service.url, domain: service.domain, overrides: [:])
            guard current.source == item.source, current.restriction == nil else {
                throw StartupError("The startup file changed after it was listed. Refresh before changing it.")
            }
            _ = try checked(StartupCommandPlanner.launchService(service, enabled: enabled, currentUID: currentUID))
            let result = try checked(StartupCommandPlanner.serviceOverrides(service.domain))
            let overrides = try StartupParsers.disabledServices(result.output)
            guard overrides[service.label] == !enabled else {
                throw StartupError("launchctl completed, but the new startup state could not be confirmed. Refresh and inspect this service.")
            }
        case let .cron(job, domain):
            try setCron(enabled: enabled, job: job, domain: domain)
        case let .loginItem(login):
            try setLoginItem(enabled: enabled, login: login)
        case .managedBackgroundItem:
            throw StartupError("Manage app-owned background items in macOS Login Items settings.")
        }
    }

    private func readCrontab(domain: StartupDomain) throws -> String {
        let arguments = domain == .system ? ["-u", "root", "-l"] : ["-l"]
        let result = try runner.run(StartupCommand("/usr/bin/crontab", arguments: arguments, administrator: domain == .system))
        if result.status == 1 && result.error.range(
            of: #"(?:^|execution error: )(?:crontab: )?no crontab for [^\n(]+(?:\s*\(1\))?\s*$"#,
            options: .regularExpression
        ) != nil {
            return ""
        }
        try requireSuccess(result, executable: "crontab")
        return result.output
    }

    private func cronItems(domain: StartupDomain) throws -> [StartupItem] {
        cronItems(text: try readCrontab(domain: domain), domain: domain)
    }

    private func cronItems(text: String, domain: StartupDomain) -> [StartupItem] {
        CronDocument(text: text).jobs.map { job in
            StartupItem(
                id: "cron/\(domain.target)/\(job.id)", name: job.schedule, kind: .cron, domain: domain,
                command: job.command, origin: domain == .system ? "root crontab" : "My crontab",
                state: job.enabled ? .enabled : .disabled, source: .cron(job, domain)
            )
        }
    }

    private func setCron(enabled: Bool, job: CronJob, domain: StartupDomain) throws {
        if case let .gui(uid) = domain, uid != currentUID { throw StartupError("Other users' cron jobs are read-only.") }
        let original = try readCrontab(domain: domain)
        let replacement = try CronDocument(text: original).setting(job: job, enabled: enabled)
        let backup = stateDirectory.appendingPathComponent("cron-\(domain == .system ? "system" : "user")-\(UUID().uuidString).txt")
        try writePrivate(Data(original.utf8), to: backup)
        let input = stateDirectory.appendingPathComponent("cron-input-\(UUID().uuidString).txt")
        try writePrivate(Data(replacement.utf8), to: input)
        defer {
            do { try manager.removeItem(at: input) }
            catch { fputs("KillSwitch could not remove private cron staging input: \(error.localizedDescription)\n", stderr) }
        }

        // Validate an immutable private copy after authorization; no crontab contents enter argv.
        let arguments = domain == .system ? "-u root " : ""
        let canonical = original.replacingOccurrences(of: #"\n+$"#, with: "", options: .regularExpression)
        let canonicalReplacement = replacement.replacingOccurrences(of: #"\n+$"#, with: "", options: .regularExpression)
        let script = """
        set -eu
        source=$1
        owner=$2
        expected_old=$3
        expected_input=$4
        expected_new=$5
        parent=${source%/*}
        if [ -L "$source" ] || [ ! -f "$source" ] || [ -L "$parent" ] || [ ! -d "$parent" ] ||
           [ "$(/usr/bin/stat -f '%u:%Lp' "$source")" != "$owner:600" ] ||
           [ "$(/usr/bin/stat -f '%u:%Lp' "$parent")" != "$owner:700" ]; then
            printf '%s\\n' 'The private cron staging input has unsafe ownership or permissions.' >&2
            exit 1
        fi
        umask 077
        private=$(/usr/bin/mktemp -d /private/tmp/killswitch-cron.XXXXXXXX)
        trap '/bin/rm -f "$private/input"; /bin/rmdir "$private"' EXIT
        trap 'exit 1' HUP INT TERM
        /bin/cp -P "$source" "$private/input"
        if [ -L "$private/input" ] || [ ! -f "$private/input" ]; then
            printf '%s\\n' 'The cron staging input changed during authorization.' >&2
            exit 1
        fi
        /bin/chmod 600 "$private/input"
        input_digest=$(/usr/bin/shasum -a 256 "$private/input")
        if [ "${input_digest%% *}" != "$expected_input" ]; then
            printf '%s\\n' 'The cron staging input changed. Refresh before changing a job.' >&2
            exit 1
        fi
        current=$(/usr/bin/crontab \(arguments)-l)
        digest=$(printf '%s' "$current" | /usr/bin/shasum -a 256)
        if [ "${digest%% *}" != "$expected_old" ]; then
            printf '%s\\n' 'The crontab changed. Refresh before changing a job.' >&2
            exit 1
        fi
        /usr/bin/crontab \(arguments)"$private/input"
        installed=$(/usr/bin/crontab \(arguments)-l)
        installed_digest=$(printf '%s' "$installed" | /usr/bin/shasum -a 256)
        if [ "${installed_digest%% *}" != "$expected_new" ]; then
            printf '%s\\n' 'The updated crontab could not be verified. Inspect the saved backup before retrying.' >&2
            exit 1
        fi
        """
        do {
            _ = try checked(StartupCommand("/bin/sh", arguments: [
                "-c", script, "killswitch-cron", input.path, String(currentUID),
                startupFingerprint(Data(canonical.utf8)), startupFingerprint(Data(replacement.utf8)),
                startupFingerprint(Data(canonicalReplacement.utf8))
            ], administrator: domain == .system))
        } catch {
            throw StartupError("\(error.localizedDescription) The previous crontab is saved in \(backup.path).")
        }
        if domain == .system { cachedSystemCron = cronItems(text: replacement, domain: domain) }
    }

    private func readLoginItems() throws -> [LegacyLoginItem] {
        let script = """
        const app = Application('System Events');
        JSON.stringify(app.loginItems().map(item => ({name: item.name(), path: item.path(), hidden: item.hidden()})));
        """
        let result = try checked(StartupCommand("/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", script]))
        return try JSONDecoder().decode([LegacyLoginItem].self, from: Data(result.output.utf8))
    }

    private func setLoginItem(enabled: Bool, login: LegacyLoginItem) throws {
        guard login.path.hasPrefix("/"), !login.path.contains("\0") else { throw StartupError("The login app path is invalid.") }
        var disabled = try readDisabledLoginItems()
        let current = try readLoginItems()
        let payload = String(decoding: try JSONEncoder().encode(login), as: UTF8.self)
        let script: String
        if enabled {
            guard disabled.contains(login), !current.contains(where: { $0.id == login.id }) else {
                throw StartupError("The login app changed after it was listed. Refresh first.")
            }
            script = """
            const app = Application('System Events');
            app.loginItems.push(app.LoginItem(\(payload)));
            """
        } else {
            guard current.filter({ $0.id == login.id }) == [login] else {
                throw StartupError("The login app changed or is ambiguous. Refresh before disabling it.")
            }
            disabled.removeAll { $0.id == login.id }
            disabled.append(login)
            try writePrivate(try JSONEncoder().encode(disabled), to: disabledLoginURL)
            script = """
            const app = Application('System Events');
            const expected = \(payload);
            const matches = app.loginItems().filter(item => item.name() === expected.name && item.path() === expected.path);
            if (matches.length !== 1) throw Error('The login app changed. Refresh first.');
            matches[0].delete();
            """
        }
        _ = try checked(StartupCommand("/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", script]))
        let exists = try readLoginItems().contains { $0.id == login.id }
        guard exists == enabled else { throw StartupError("The new login-app state could not be confirmed. Refresh before trying again.") }
        if enabled {
            disabled.removeAll { $0.id == login.id }
            try writePrivate(try JSONEncoder().encode(disabled), to: disabledLoginURL)
        }
    }

    private var disabledLoginURL: URL { stateDirectory.appendingPathComponent("disabled-login-apps.json") }

    private func readDisabledLoginItems() throws -> [LegacyLoginItem] {
        guard manager.fileExists(atPath: disabledLoginURL.path) else { return [] }
        let attributes = try manager.attributesOfItem(atPath: disabledLoginURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw StartupError("The saved login-app state is not a regular file.")
        }
        return try JSONDecoder().decode([LegacyLoginItem].self, from: Data(contentsOf: disabledLoginURL))
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try manager.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = try manager.attributesOfItem(atPath: stateDirectory.path)
        guard directory[.type] as? FileAttributeType == .typeDirectory else {
            throw StartupError("The startup backup location must be a real directory.")
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        if manager.fileExists(atPath: url.path) {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw StartupError("Refusing to overwrite a linked or non-file startup backup.")
            }
        }
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func checked(_ command: StartupCommand) throws -> StartupCommandResult {
        let result = try runner.run(command)
        try requireSuccess(result, executable: command.executable)
        return result
    }

    private func requireSuccess(_ result: StartupCommandResult, executable: String) throws {
        guard result.status == 0 else {
            let detail = [result.error, result.output].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("-128") || detail.localizedCaseInsensitiveContains("user canceled") {
                throw StartupError("Administrator authorization was cancelled. No success was assumed; refresh to inspect the current state.")
            }
            throw StartupError("\(executable) exited with status \(result.status): \(detail.isEmpty ? "No error details were returned." : detail)")
        }
    }
}
