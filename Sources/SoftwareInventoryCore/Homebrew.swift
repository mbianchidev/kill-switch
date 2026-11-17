import Foundation

public enum HomebrewPackageKind: String, CaseIterable, Sendable {
    case formula
    case cask

    public var title: String { self == .formula ? "Formula" : "Cask" }
}

public struct HomebrewPackage: Identifiable, Equatable, Sendable {
    public var id: String { "\(kind.rawValue):\(fullName)" }

    public let kind: HomebrewPackageKind
    /// Short name or cask token.
    public let name: String
    /// Tap-qualified name used for commands, for example `user/tap/tool`.
    public let fullName: String
    public let displayName: String
    public let summary: String?
    public let installedVersion: String?
    public let latestVersion: String?
    public let isOutdated: Bool
    /// Casks that update themselves; Homebrew never upgrades these from KillSwitch.
    public let autoUpdates: Bool
    public let isPinned: Bool
    public let isDeprecated: Bool
    public let isDisabled: Bool
    public let installedOnRequest: Bool
    /// Installed application bundle paths for casks.
    public let appPaths: [String]
    /// Bundle identifiers a cask's uninstall stanza quits; a running one means the app is in use.
    public let quitBundleIDs: [String]

    public init(
        kind: HomebrewPackageKind, name: String, fullName: String, displayName: String, summary: String?,
        installedVersion: String?, latestVersion: String?, isOutdated: Bool, autoUpdates: Bool = false,
        isPinned: Bool = false, isDeprecated: Bool = false, isDisabled: Bool = false,
        installedOnRequest: Bool = true, appPaths: [String] = [], quitBundleIDs: [String] = []
    ) {
        self.kind = kind
        self.name = name
        self.fullName = fullName
        self.displayName = displayName
        self.summary = summary
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.isOutdated = isOutdated
        self.autoUpdates = autoUpdates
        self.isPinned = isPinned
        self.isDeprecated = isDeprecated
        self.isDisabled = isDisabled
        self.installedOnRequest = installedOnRequest
        self.appPaths = appPaths
        self.quitBundleIDs = quitBundleIDs
    }

    /// Unversioned casks cannot be compared, so Homebrew only reinstalls them when forced.
    public var isUnversionedCask: Bool { kind == .cask && installedVersion == "latest" }

    /// Why this package is excluded from upgrades, or nil when KillSwitch may upgrade it.
    public var upgradeRestriction: String? {
        if !isOutdated { return "It is already up to date." }
        if autoUpdates { return "This app updates itself, so Homebrew upgrades are skipped." }
        if isUnversionedCask { return "This cask is unversioned, so Homebrew cannot tell whether it is outdated." }
        if isPinned { return "This package is pinned in Homebrew." }
        return nil
    }

    public var canUpgrade: Bool { upgradeRestriction == nil }
}

public struct HomebrewInstallation: Equatable, Sendable {
    public static let standardExecutables = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public let executable: String

    public init(executable: String) {
        self.executable = executable
    }

    public var prefix: String {
        URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().path
    }

    /// Finds Homebrew in its standard Apple silicon or Intel location. KillSwitch never installs it.
    public static func locate(
        candidates: [String] = standardExecutables,
        fileManager: FileManager = .default
    ) -> HomebrewInstallation? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }.map(HomebrewInstallation.init)
    }

    /// Commands never auto-update metadata, so they act on exactly the listed versions.
    public var environment: [String: String] {
        [
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_COLOR": "1",
            "HOMEBREW_NO_EMOJI": "1",
            "PATH": "\(prefix)/bin:\(prefix)/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]
    }

    public func command(_ arguments: [String]) -> SoftwareCommand {
        SoftwareCommand(executable, arguments: arguments, environment: environment)
    }

    public var infoCommand: SoftwareCommand { command(["info", "--json=v2", "--installed"]) }
    public var outdatedCommand: SoftwareCommand { command(["outdated", "--json=v2"]) }
    public var updateCommand: SoftwareCommand { command(["update"]) }
}

public enum HomebrewError: LocalizedError, Equatable, Sendable {
    case notInstalled
    case unsafeName(String)
    case upgradeNotAllowed(String, String)
    case nothingToUpgrade

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Homebrew is not installed in /opt/homebrew or /usr/local."
        case .unsafeName(let name):
            return "Refusing to pass an unexpected Homebrew package name to brew: \(name)"
        case let .upgradeNotAllowed(name, reason):
            return "\(name) cannot be upgraded: \(reason)"
        case .nothingToUpgrade:
            return "No outdated packages can be upgraded."
        }
    }
}

/// Which casks are in use. Homebrew replaces a cask's whole bundle, which deletes files a
/// running app still loads, so a running cask is never upgraded.
public enum RunningCaskDetector {
    public static let processListCommand = SoftwareCommand("/bin/ps", arguments: ["-axo", "comm="])

    /// Returns the full names of running casks, or nil when running state is unknown.
    public static func runningCasks(
        _ packages: [HomebrewPackage], installation: HomebrewInstallation,
        processPaths: [String]?, runningBundleIDs: Set<String>?,
        bundleIdentifier: (String) -> String? = RunningCaskDetector.bundleIdentifier
    ) -> Set<String>? {
        guard let processPaths, let runningBundleIDs else { return nil }
        var running = Set<String>()
        for package in packages where package.kind == .cask {
            let caskroom = "\(installation.prefix)/Caskroom/\(package.name)/"
            let roots = package.appPaths.map { $0.hasSuffix("/") ? $0 : $0 + "/" } + [caskroom]
            let bundles = Set(package.appPaths.compactMap(bundleIdentifier) + package.quitBundleIDs)
            if processPaths.contains(where: { path in roots.contains { path.hasPrefix($0) } })
                || !bundles.isDisjoint(with: runningBundleIDs) {
                running.insert(package.fullName)
            }
        }
        return running
    }

    public static func processPaths(runner: SoftwareCommandRunning) -> [String]? {
        guard let result = try? runner.run(processListCommand), result.succeeded else { return nil }
        let paths = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return paths.isEmpty ? nil : paths
    }

    public static func bundleIdentifier(_ appPath: String) -> String? {
        let url = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }
}

public enum HomebrewCommandPlanner {
    /// Why a cask is kept for its running state, or nil. Unknown running state keeps every cask.
    public static func runningRestriction(_ package: HomebrewPackage, running: Set<String>?) -> String? {
        guard package.kind == .cask else { return nil }
        guard let running else { return "Running apps could not be listed, so casks are not upgraded." }
        return running.contains(package.fullName) ? "\(package.displayName) is running. Quit it, then upgrade." : nil
    }

    /// Upgrades only the listed outdated packages, never self-updating, unversioned, pinned, or
    /// running ones. Naming packages also prevents a user's greedy Homebrew setting from applying.
    /// Casks upgrade one at a time so a failure or newly running app affects only that cask.
    public static func upgradeAll(
        _ packages: [HomebrewPackage], installation: HomebrewInstallation, running: Set<String>?
    ) throws -> [SoftwareCommand] {
        var commands: [SoftwareCommand] = []
        let formulae = packages.filter { $0.kind == .formula && $0.canUpgrade }.map(\.fullName).sorted()
        if !formulae.isEmpty {
            try formulae.forEach(validate)
            commands.append(installation.command(["upgrade", "--formula"] + formulae))
        }
        for cask in packages.filter({ $0.kind == .cask && $0.canUpgrade && runningRestriction($0, running: running) == nil })
            .sorted(by: { $0.fullName < $1.fullName }) {
            try validate(cask.fullName)
            commands.append(installation.command(["upgrade", "--cask", cask.fullName]))
        }
        guard !commands.isEmpty else { throw HomebrewError.nothingToUpgrade }
        return commands
    }

    public static func upgrade(
        _ package: HomebrewPackage, installation: HomebrewInstallation, running: Set<String>?
    ) throws -> SoftwareCommand {
        if let reason = package.upgradeRestriction ?? runningRestriction(package, running: running) {
            throw HomebrewError.upgradeNotAllowed(package.displayName, reason)
        }
        try validate(package.fullName)
        return installation.command(["upgrade", "--\(package.kind.rawValue)", package.fullName])
    }

    /// Plain uninstall: no `--force`, `--zap`, or `--ignore-dependencies`, so Homebrew keeps
    /// refusing to remove formulae that installed packages still depend on.
    public static func uninstall(
        _ package: HomebrewPackage, installation: HomebrewInstallation
    ) throws -> SoftwareCommand {
        try validate(package.fullName)
        return installation.command(["uninstall", "--\(package.kind.rawValue)", package.fullName])
    }

    static func validate(_ name: String) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._+-/")
        guard !name.isEmpty, name.first != "-", name.allSatisfy(allowed.contains) else {
            throw HomebrewError.unsafeName(name)
        }
    }
}

public enum HomebrewInventoryParser {
    public static func parse(info: Data, outdated: Data) throws -> [HomebrewPackage] {
        let decoder = JSONDecoder()
        let installed = try decoder.decode(InfoDocument.self, from: info)
        let stale = try decoder.decode(OutdatedDocument.self, from: outdated)
        var latestFormulae: [String: String] = [:]
        for entry in stale.formulae ?? [] { latestFormulae[entry.name] = entry.currentVersion ?? "" }
        var latestCasks: [String: String] = [:]
        for entry in stale.casks ?? [] { latestCasks[entry.name] = entry.currentVersion ?? "" }

        let formulae = (installed.formulae ?? []).map { formula -> HomebrewPackage in
            let fullName = formula.fullName ?? formula.name
            let latest = latestFormulae[fullName] ?? latestFormulae[formula.name]
            let record = formula.installed?.last
            return HomebrewPackage(
                kind: .formula, name: formula.name, fullName: fullName, displayName: formula.name,
                summary: formula.desc, installedVersion: formula.linkedKeg ?? record?.version,
                latestVersion: latest.flatMap { $0.isEmpty ? nil : $0 } ?? formula.versions?.stable,
                isOutdated: latest != nil, isPinned: formula.pinned ?? false,
                isDeprecated: formula.deprecated ?? false, isDisabled: formula.disabled ?? false,
                installedOnRequest: record?.installedOnRequest ?? true
            )
        }
        let casks = (installed.casks ?? []).map { cask -> HomebrewPackage in
            let fullName = cask.fullToken ?? cask.token
            let latest = latestCasks[fullName] ?? latestCasks[cask.token]
            return HomebrewPackage(
                kind: .cask, name: cask.token, fullName: fullName,
                displayName: cask.name?.first ?? cask.token, summary: cask.desc,
                installedVersion: cask.installed, latestVersion: latest.flatMap { $0.isEmpty ? nil : $0 } ?? cask.version,
                isOutdated: latest != nil, autoUpdates: cask.autoUpdates ?? false,
                isPinned: cask.pinned ?? false, isDeprecated: cask.deprecated ?? false,
                isDisabled: cask.disabled ?? false,
                appPaths: (cask.artifacts ?? []).flatMap(\.appPaths),
                quitBundleIDs: (cask.artifacts ?? []).flatMap(\.quitBundleIDs)
            )
        }
        return (formulae + casks).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Maps installed application paths to the cask that installed them.
    public static func casksByApplicationPath(_ packages: [HomebrewPackage]) -> [String: HomebrewPackage] {
        var result: [String: HomebrewPackage] = [:]
        for package in packages where package.kind == .cask {
            for path in package.appPaths {
                result[URL(fileURLWithPath: path).standardizedFileURL.path] = package
            }
        }
        return result
    }

    private struct InfoDocument: Decodable {
        let formulae: [Formula]?
        let casks: [Cask]?
    }

    private struct Formula: Decodable {
        struct Installed: Decodable {
            let version: String?
            let installedOnRequest: Bool?
            enum CodingKeys: String, CodingKey {
                case version
                case installedOnRequest = "installed_on_request"
            }
        }
        struct Versions: Decodable { let stable: String? }

        let name: String
        let fullName: String?
        let desc: String?
        let installed: [Installed]?
        let linkedKeg: String?
        let pinned: Bool?
        let deprecated: Bool?
        let disabled: Bool?
        let versions: Versions?

        enum CodingKeys: String, CodingKey {
            case name, desc, installed, pinned, deprecated, disabled, versions
            case fullName = "full_name"
            case linkedKeg = "linked_keg"
        }
    }

    private struct Cask: Decodable {
        let token: String
        let fullToken: String?
        let name: [String]?
        let desc: String?
        let installed: String?
        let version: String?
        let autoUpdates: Bool?
        let pinned: Bool?
        let deprecated: Bool?
        let disabled: Bool?
        let artifacts: [Artifact]?

        enum CodingKeys: String, CodingKey {
            case token, name, desc, installed, version, pinned, deprecated, disabled, artifacts
            case fullToken = "full_token"
            case autoUpdates = "auto_updates"
        }
    }

    /// Cask artifacts are heterogeneous; only `app` entries are read. Newer Homebrew reports
    /// the installed `target`; older output names the bundle relative to `/Applications`.
    private struct Artifact: Decodable {
        let appPaths: [String]
        let quitBundleIDs: [String]

        private struct Uninstall: Decodable {
            let quit: [String]

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                if let single = try? container.decode(String.self, forKey: Key(stringValue: "quit")) {
                    quit = [single]
                } else {
                    quit = (try? container.decode([String].self, forKey: Key(stringValue: "quit"))) ?? []
                }
            }
        }

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        private enum Element: Decodable {
            case name(String)
            case options([String: String])
            case other

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let name = try? container.decode(String.self) {
                    self = .name(name)
                } else if let options = try? container.decode([String: String].self) {
                    self = .options(options)
                } else {
                    self = .other
                }
            }
        }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: Key.self)
            quitBundleIDs = ((try? container?.decode([Uninstall].self, forKey: Key(stringValue: "uninstall"))) ?? [])?
                .flatMap(\.quit) ?? []
            guard let container, let elements = try? container.decode([Element].self, forKey: Key(stringValue: "app")) else {
                appPaths = []
                return
            }
            if let target = try? container.decode(String.self, forKey: Key(stringValue: "target")) {
                appPaths = [target]
                return
            }
            // `["Source.app", {"target": "Renamed.app"}]` installs the source under its target name.
            var paths: [String] = []
            for element in elements {
                switch element {
                case .name(let name):
                    paths.append(Self.absolute(name))
                case .options(let options):
                    if let target = options["target"], !paths.isEmpty {
                        paths[paths.count - 1] = Self.absolute(target)
                    }
                case .other:
                    continue
                }
            }
            appPaths = paths
        }

        private static func absolute(_ path: String) -> String {
            path.hasPrefix("/") ? path : "/Applications/\(path)"
        }
    }

    private struct OutdatedDocument: Decodable {
        struct Entry: Decodable {
            let name: String
            let currentVersion: String?
            enum CodingKeys: String, CodingKey {
                case name
                case currentVersion = "current_version"
            }
        }

        let formulae: [Entry]?
        let casks: [Entry]?
    }
}

/// Loads the installed inventory and runs planned commands through an injectable runner.
public struct HomebrewService: Sendable {
    public let installation: HomebrewInstallation
    private let runner: SoftwareCommandRunning

    public init(installation: HomebrewInstallation, runner: SoftwareCommandRunning = NativeSoftwareCommandRunner()) {
        self.installation = installation
        self.runner = runner
    }

    public func loadPackages() throws -> [HomebrewPackage] {
        let info = try runner.checkedOutput(installation.infoCommand)
        let outdated = try runner.checkedOutput(installation.outdatedCommand)
        do {
            return try HomebrewInventoryParser.parse(info: Data(info.utf8), outdated: Data(outdated.utf8))
        } catch {
            throw SoftwareCommandError.unreadableOutput(
                command: installation.infoCommand.displayString, message: error.localizedDescription
            )
        }
    }

    /// Runs commands in order and stops at the first failure, keeping the transcript so far.
    /// `skip` is asked just before each command; a returned reason skips it without failing.
    public func perform(_ commands: [SoftwareCommand], skip: (SoftwareCommand) -> String? = { _ in nil }) -> HomebrewTranscript {
        var lines: [String] = []
        for command in commands {
            if let reason = skip(command) {
                lines.append("Skipped \(command.displayString): \(reason)")
                continue
            }
            lines.append("$ \(command.displayString)")
            let result: SoftwareCommandResult
            do {
                result = try runner.run(command)
            } catch {
                return HomebrewTranscript(lines: lines, failure: error.localizedDescription)
            }
            let output = [result.output, result.error]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            lines.append(contentsOf: output)
            guard result.succeeded else {
                let failure = SoftwareCommandError.failed(
                    command: command.displayString, status: result.status,
                    message: result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                return HomebrewTranscript(lines: lines, failure: failure.localizedDescription)
            }
        }
        return HomebrewTranscript(lines: lines, failure: nil)
    }
}

public struct HomebrewTranscript: Equatable, Sendable {
    public let lines: [String]
    /// Set when a command could not start or exited unsuccessfully.
    public let failure: String?

    public init(lines: [String], failure: String?) {
        self.lines = lines
        self.failure = failure
    }

    public var text: String { lines.joined(separator: "\n") }
}
