import Foundation

public enum DevCleanupCLICommand: Equatable {
    case status
    case syncPorts(source: String, ports: [Int])
    case cleanup
}

public enum DevCleanupCLIParseError: LocalizedError, Equatable {
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        }
    }
}

public enum DevCleanupCLIParser {
    public static func parse(_ arguments: [String]) throws -> DevCleanupCLICommand {
        guard arguments.count >= 3, arguments[0] == "dev-cleanup" else {
            throw usage("Expected a dev-cleanup command.")
        }

        switch arguments[1] {
        case "status":
            try requireJSONOnly(Array(arguments.dropFirst(2)))
            return .status
        case "cleanup":
            try requireJSONOnly(Array(arguments.dropFirst(2)))
            return .cleanup
        case "sync-ports":
            return try parseSyncPorts(Array(arguments.dropFirst(2)))
        default:
            throw usage("Unknown dev-cleanup command '\(arguments[1])'.")
        }
    }

    private static func requireJSONOnly(_ arguments: [String]) throws {
        guard arguments == ["--json"] else {
            throw usage("This command requires exactly the --json flag.")
        }
    }

    private static func parseSyncPorts(_ arguments: [String]) throws -> DevCleanupCLICommand {
        var source: String?
        var portsValue: String?
        var sawPorts = false
        var sawJSON = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                guard !sawJSON else { throw usage("Duplicate --json flag.") }
                sawJSON = true
            case "--source":
                guard source == nil else { throw usage("Duplicate --source option.") }
                index += 1
                guard index < arguments.count else {
                    throw usage("--source requires a value.")
                }
                source = arguments[index]
            case "--ports":
                guard !sawPorts else { throw usage("Duplicate --ports option.") }
                sawPorts = true
                index += 1
                guard index < arguments.count else {
                    throw usage("--ports requires a value; use --ports= to clear the source.")
                }
                portsValue = arguments[index]
            default:
                if argument.hasPrefix("--source=") {
                    guard source == nil else { throw usage("Duplicate --source option.") }
                    source = String(argument.dropFirst("--source=".count))
                } else if argument.hasPrefix("--ports=") {
                    guard !sawPorts else { throw usage("Duplicate --ports option.") }
                    sawPorts = true
                    portsValue = String(argument.dropFirst("--ports=".count))
                } else {
                    throw usage("Unknown option '\(argument)'.")
                }
            }
            index += 1
        }

        guard sawJSON else { throw usage("Missing required --json flag.") }
        guard let rawSource = source else { throw usage("Missing required --source option.") }
        guard sawPorts, let rawPorts = portsValue else {
            throw usage("Missing required --ports option; use --ports= to clear the source.")
        }

        let normalizedSource: String
        do {
            normalizedSource = try DevCleanupPreferences.normalizedSource(rawSource)
        } catch {
            throw usage(error.localizedDescription)
        }
        return .syncPorts(source: normalizedSource, ports: try parsePorts(rawPorts))
    }

    private static func parsePorts(_ rawPorts: String) throws -> [Int] {
        let trimmed = rawPorts.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        let components = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        var ports: [Int] = []
        for component in components {
            let value = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, let port = Int(value) else {
                throw usage("Invalid port list '\(rawPorts)'. Use comma-separated integers.")
            }
            guard (1...65535).contains(port) else {
                throw usage("Invalid port \(port). Ports must be between 1 and 65535.")
            }
            ports.append(port)
        }
        return DevCleanupPreferences.normalizedPorts(ports)
    }

    private static func usage(_ message: String) -> DevCleanupCLIParseError {
        .invalidArguments(
            "\(message) Usage: killswitchctl dev-cleanup <status|cleanup> --json, or " +
            "killswitchctl dev-cleanup sync-ports --source <name> --ports <csv> --json."
        )
    }
}
