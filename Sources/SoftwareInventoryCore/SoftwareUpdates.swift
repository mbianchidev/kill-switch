import Foundation

public enum SoftwareUpdateCategory: String, Sendable {
    case securityResponse = "Security response"
    case macOSUpdate = "macOS update"
    case macOSUpgrade = "macOS upgrade"
    case safari = "Safari update"
    case other = "Other update"

    /// Apple ships security fixes as security responses, updates within the installed macOS
    /// major version, and Safari updates; major upgrades and other software are not highlighted.
    public var isSecurityRelevant: Bool {
        switch self {
        case .securityResponse, .macOSUpdate, .safari: return true
        case .macOSUpgrade, .other: return false
        }
    }
}

public struct SoftwareUpdateItem: Identifiable, Equatable, Sendable {
    public var id: String { label }

    public let label: String
    public let title: String
    public let version: String?
    public let sizeKiB: UInt64?
    public let recommended: Bool
    public let requiresRestart: Bool
    public let category: SoftwareUpdateCategory

    public init(
        label: String, title: String, version: String?, sizeKiB: UInt64?,
        recommended: Bool, requiresRestart: Bool, category: SoftwareUpdateCategory
    ) {
        self.label = label
        self.title = title
        self.version = version
        self.sizeKiB = sizeKiB
        self.recommended = recommended
        self.requiresRestart = requiresRestart
        self.category = category
    }

    public var sizeBytes: UInt64? { sizeKiB.map { $0 * 1_024 } }
}

public struct SoftwareUpdateList: Equatable, Sendable {
    public let items: [SoftwareUpdateItem]
    /// Non-fatal problems reported by `softwareupdate`, such as a busy or failed scan.
    public let warnings: [String]

    public init(items: [SoftwareUpdateItem], warnings: [String]) {
        self.items = items
        self.warnings = warnings
    }
}

public enum SoftwareUpdateParser {
    /// `--no-scan` reuses the most recent macOS scan; a full scan contacts Apple and can be slow.
    public static func listCommand(scan: Bool) -> SoftwareCommand {
        SoftwareCommand("/usr/sbin/softwareupdate", arguments: scan ? ["--list"] : ["--list", "--no-scan"])
    }

    public static func parse(output: String, error: String, currentMajorVersion: Int) -> SoftwareUpdateList {
        var items: [SoftwareUpdateItem] = []
        var warnings: [String] = []
        var label: String?

        for rawLine in (output + "\n" + error).split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* Label:") {
                label = line.dropFirst("* Label:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Title:"), let current = label {
                items.append(item(label: current, details: line, currentMajorVersion: currentMajorVersion))
                label = nil
            } else if line.localizedCaseInsensitiveContains("error") {
                warnings.append(readableWarning(line))
            }
        }
        if let label {
            items.append(item(label: label, details: "", currentMajorVersion: currentMajorVersion))
        }
        return SoftwareUpdateList(items: items, warnings: warnings)
    }

    static func item(label: String, details: String, currentMajorVersion: Int) -> SoftwareUpdateItem {
        let knownKeys: Set<String> = ["Title", "Version", "Size", "Recommended", "Action"]
        var fields: [String: String] = [:]
        var lastKey: String?
        for segment in details.components(separatedBy: ", ") {
            let parts = segment.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, knownKeys.contains(parts[0]) {
                fields[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                lastKey = parts[0]
            } else if let key = lastKey, !segment.trimmingCharacters(in: .whitespaces).isEmpty {
                // A title may itself contain ", ".
                fields[key, default: ""] += ", " + segment.trimmingCharacters(in: .whitespaces)
            }
        }
        let title = fields["Title"].flatMap { $0.isEmpty ? nil : $0 } ?? label
        let version = fields["Version"].flatMap { $0.isEmpty ? nil : $0 }
        let size = fields["Size"].flatMap { UInt64($0.replacingOccurrences(of: "KiB", with: "").trimmingCharacters(in: .whitespaces)) }
        return SoftwareUpdateItem(
            label: label, title: title, version: version, sizeKiB: size,
            recommended: fields["Recommended"]?.uppercased() == "YES",
            requiresRestart: fields["Action"]?.lowercased() == "restart",
            category: category(label: label, title: title, version: version, currentMajorVersion: currentMajorVersion)
        )
    }

    static func category(label: String, title: String, version: String?, currentMajorVersion: Int) -> SoftwareUpdateCategory {
        if label.localizedCaseInsensitiveContains("security") || title.localizedCaseInsensitiveContains("security") {
            return .securityResponse
        }
        if title.hasPrefix("macOS") {
            let major = version.flatMap { $0.split(separator: ".").first.flatMap { Int($0) } }
            return major == currentMajorVersion ? .macOSUpdate : .macOSUpgrade
        }
        if title.hasPrefix("Safari") { return .safari }
        return .other
    }

    private static func readableWarning(_ line: String) -> String {
        if let range = line.range(of: "NSLocalizedDescription=") {
            let description = line[range.upperBound...].prefix { $0 != "}" }
            return description.trimmingCharacters(in: .whitespaces)
        }
        return line
    }
}

public struct SoftwareUpdateService: Sendable {
    private let runner: SoftwareCommandRunning

    public init(runner: SoftwareCommandRunning = NativeSoftwareCommandRunner()) {
        self.runner = runner
    }

    public func list(scan: Bool, currentMajorVersion: Int) throws -> SoftwareUpdateList {
        let command = SoftwareUpdateParser.listCommand(scan: scan)
        let result = try runner.run(command)
        let list = SoftwareUpdateParser.parse(
            output: result.output, error: result.error, currentMajorVersion: currentMajorVersion
        )
        guard result.succeeded else {
            throw SoftwareCommandError.failed(
                command: command.displayString, status: result.status,
                message: list.warnings.last ?? result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return list
    }
}
