import CryptoKit
import Foundation
import InstallCore

public enum StartupKind: String, CaseIterable, Identifiable, Sendable {
    case loginApp = "Login apps"
    case backgroundItem = "App background items"
    case agent = "Launch agents"
    case daemon = "System services"
    case cron = "Cron jobs"
    public var id: Self { self }
}

public enum StartupState: String, CaseIterable, Identifiable, Sendable {
    case enabled = "Enabled"
    case disabled = "Disabled"
    case unknown = "Unknown"
    public var id: Self { self }
}

public enum StartupDomain: Equatable, Sendable {
    case gui(UInt32)
    case system

    public var target: String {
        switch self {
        case let .gui(uid): return "gui/\(uid)"
        case .system: return "system"
        }
    }

    public var label: String {
        switch self {
        case .gui: return "My account"
        case .system: return "System"
        }
    }
}

public struct LaunchService: Equatable, Sendable {
    public var label: String
    public let url: URL
    public var domain: StartupDomain
    public let program: String
    public let fingerprint: String?

    public init(label: String, url: URL, domain: StartupDomain, program: String, fingerprint: String? = nil) {
        self.label = label
        self.url = url
        self.domain = domain
        self.program = program
        self.fingerprint = fingerprint
    }
}

public struct LegacyLoginItem: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let hidden: Bool
    public var id: String { "login/\(startupFingerprint(Data((name + "\0" + path).utf8)))" }

    public init(name: String, path: String, hidden: Bool) {
        self.name = name
        self.path = path
        self.hidden = hidden
    }
}

public enum StartupSource: Equatable, Sendable {
    case launchService(LaunchService)
    case cron(CronJob, StartupDomain)
    case loginItem(LegacyLoginItem)
    case managedBackgroundItem(String)
}

public struct StartupItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: StartupKind
    public let domain: StartupDomain
    public let command: String
    public let origin: String
    public let state: StartupState
    public var restriction: String?
    public let source: StartupSource

    public init(
        id: String, name: String, kind: StartupKind, domain: StartupDomain,
        command: String, origin: String, state: StartupState, restriction: String? = nil, source: StartupSource
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.domain = domain
        self.command = command
        self.origin = origin
        self.state = state
        self.restriction = restriction
        self.source = source
    }
}

public struct StartupError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct StartupCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let administrator: Bool

    public init(_ executable: String, arguments: [String], administrator: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.administrator = administrator
    }
}

public struct StartupCommandResult {
    public let status: Int32
    public let output: String
    public let error: String
    public init(status: Int32, output: String, error: String) {
        self.status = status
        self.output = output
        self.error = error
    }
}

public protocol StartupCommandRunning {
    func run(_ command: StartupCommand) throws -> StartupCommandResult
}

public struct NativeStartupCommandRunner: StartupCommandRunning {
    public init() {}

    public static func administratorOutput(_ output: String) -> String {
        output.hasSuffix("\n") ? String(output.dropLast()) : output
    }

    public func run(_ command: StartupCommand) throws -> StartupCommandResult {
        let result: CommandResult
        if command.administrator {
            let shell = ([command.executable] + command.arguments).map(CommandRunner.shellQuote).joined(separator: " ")
            let script = "do shell script \(CommandRunner.appleScriptLiteral(shell)) with administrator privileges without altering line endings"
            result = try CommandRunner.run("/usr/bin/osascript", arguments: ["-e", script], environment: ["LC_ALL": "C"])
        } else {
            result = try CommandRunner.run(command.executable, arguments: command.arguments, environment: ["LC_ALL": "C"])
        }
        let output = command.administrator && result.succeeded
            ? Self.administratorOutput(result.standardOutput) : result.standardOutput
        return StartupCommandResult(status: result.status, output: output, error: result.standardError)
    }
}

public enum StartupCommandPlanner {
    public static func serviceOverrides(_ domain: StartupDomain) -> StartupCommand {
        StartupCommand("/bin/launchctl", arguments: ["print-disabled", domain.target])
    }

    public static func launchService(
        _ service: LaunchService, enabled: Bool, currentUID: UInt32
    ) throws -> StartupCommand {
        let path = service.url.resolvingSymlinksInPath().path
        guard !service.label.lowercased().hasPrefix("com.apple."),
              !path.hasPrefix("/System/"), !path.hasPrefix("/usr/lib/"),
              !service.program.hasPrefix("/System/"), !service.program.hasPrefix("/usr/libexec/") else {
            throw StartupError("Protected macOS services are read-only.")
        }
        guard service.label.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else {
            throw StartupError("This service label cannot be safely managed.")
        }
        if case let .gui(uid) = service.domain, uid != currentUID {
            throw StartupError("Services belonging to another user account are read-only.")
        }
        return StartupCommand(
            "/bin/launchctl",
            arguments: [enabled ? "enable" : "disable", "\(service.domain.target)/\(service.label)"],
            administrator: service.domain == .system
        )
    }
}

public struct CronJob: Equatable, Sendable {
    public let line: Int
    public let originalLine: String
    public let documentFingerprint: String
    public let schedule: String
    public let command: String
    public let enabled: Bool
    public var id: String { "\(documentFingerprint)/\(line)" }
}

public struct CronDocument: Sendable {
    public static let disabledPrefix = "# KillSwitch disabled: "
    public let text: String
    public let jobs: [CronJob]

    public init(text: String) {
        self.text = text
        let fingerprint = startupFingerprint(Data(text.utf8))
        var jobs: [CronJob] = []
        for (index, original) in text.components(separatedBy: "\n").enumerated() {
            let enabled = !original.hasPrefix(Self.disabledPrefix)
            let content = enabled ? original : String(original.dropFirst(Self.disabledPrefix.count))
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*="#, options: .regularExpression) == nil else { continue }
            let fields: [String]
            let schedule: String
            let command: String
            if trimmed.hasPrefix("@") {
                fields = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
                guard fields.count == 2,
                      ["@reboot", "@yearly", "@annually", "@monthly", "@weekly", "@daily", "@midnight", "@hourly"].contains(fields[0]) else { continue }
                schedule = fields[0]
                command = fields[1]
            } else {
                fields = trimmed.split(maxSplits: 5, whereSeparator: \.isWhitespace).map(String.init)
                guard fields.count == 6, fields.prefix(5).allSatisfy({
                    $0.range(of: #"^[A-Za-z0-9*/?,\-]+$"#, options: .regularExpression) != nil
                }) else { continue }
                schedule = fields.prefix(5).joined(separator: " ")
                command = fields[5]
            }
            jobs.append(CronJob(
                line: index, originalLine: original, documentFingerprint: fingerprint,
                schedule: schedule, command: command, enabled: enabled
            ))
        }
        self.jobs = jobs
    }

    public func setting(job: CronJob, enabled: Bool) throws -> String {
        guard startupFingerprint(Data(text.utf8)) == job.documentFingerprint,
              jobs.contains(job) else {
            throw StartupError("The crontab changed after it was listed. Refresh before changing a job.")
        }
        guard job.enabled != enabled else { return text }
        var lines = text.components(separatedBy: "\n")
        lines[job.line] = enabled
            ? String(job.originalLine.dropFirst(Self.disabledPrefix.count))
            : Self.disabledPrefix + job.originalLine
        return lines.joined(separator: "\n")
    }
}

func startupFingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
