import Foundation

public enum SecurityCheckState: String, Equatable, Sendable {
    case enabled = "On"
    case disabled = "Off"
    case unknown = "Unknown"
}

public enum SecurityCheckID: String, CaseIterable, Sendable {
    case fileVault, firewall, stealthMode, gatekeeper, systemIntegrity, xprotect, securityResponses
}

public struct SecurityCheck: Identifiable, Equatable, Sendable {
    public let id: SecurityCheckID
    public let title: String
    public let state: SecurityCheckState
    public let detail: String
    /// Whether this protection being off weakens the Mac's default security.
    public let recommendedOn: Bool

    public init(id: SecurityCheckID, title: String, state: SecurityCheckState, detail: String, recommendedOn: Bool = true) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.recommendedOn = recommendedOn
    }

    public var needsAttention: Bool { recommendedOn && state == .disabled }
}

public enum SecurityPostureParser {
    public static func fileVault(_ output: String) -> SecurityCheckState {
        let text = output.lowercased()
        if text.contains("filevault is on") || text.contains("encryption in progress") { return .enabled }
        if text.contains("filevault is off") || text.contains("decryption in progress") { return .disabled }
        return .unknown
    }

    public static func firewall(_ output: String) -> SecurityCheckState {
        let text = output.lowercased()
        if text.contains("state = 1") || text.contains("state = 2") || text.contains("firewall is enabled") {
            return .enabled
        }
        if text.contains("state = 0") || text.contains("firewall is disabled") { return .disabled }
        return .unknown
    }

    public static func stealthMode(_ output: String) -> SecurityCheckState {
        let text = output.lowercased()
        if text.contains("stealth mode is on") || text.contains("stealth mode enabled") { return .enabled }
        if text.contains("stealth mode is off") || text.contains("stealth mode disabled") { return .disabled }
        return .unknown
    }

    public static func gatekeeper(_ output: String) -> SecurityCheckState {
        let text = output.lowercased()
        if text.contains("assessments enabled") { return .enabled }
        if text.contains("assessments disabled") { return .disabled }
        return .unknown
    }

    public static func systemIntegrity(_ output: String) -> SecurityCheckState {
        let text = output.lowercased()
        guard let range = text.range(of: "protection status:") else { return .unknown }
        let status = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if status.hasPrefix("enabled") { return .enabled }
        if status.hasPrefix("disabled") { return .disabled }
        return .unknown
    }

    /// `CriticalUpdateInstall` controls "Install Security Responses and system files".
    public static func securityResponses(_ preferences: [String: Any]?) -> (SecurityCheckState, String) {
        guard let preferences else {
            return (.unknown, "Software Update preferences could not be read.")
        }
        guard let value = preferences["CriticalUpdateInstall"] as? Bool else {
            return (.unknown, "Not set explicitly; the macOS default applies.")
        }
        return value
            ? (.enabled, "Security Responses and system files install automatically.")
            : (.disabled, "Security Responses and system files do not install automatically.")
    }

    public static func xprotectVersion(_ info: [String: Any]?) -> String? {
        (info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String)
    }

    /// Reads `xprotect version` output such as `Version: 5372 Installed: 2026-01-01 ...`.
    public static func xprotectCommandVersion(_ output: String) -> String? {
        let words = output.split(whereSeparator: \.isWhitespace)
        guard let index = words.firstIndex(of: "Version:"), words.indices.contains(index + 1) else { return nil }
        let version = words[index + 1]
        return version.allSatisfy { $0.isNumber || $0 == "." } ? String(version) : nil
    }
}

public struct SecurityPostureService: Sendable {
    public static let xprotectInfo = URL(fileURLWithPath: "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist")
    /// On macOS 15 and later the active rules live outside the CoreServices bundle, which can lag;
    /// this command reports the active version. Older systems lack it and use the bundle.
    public static let xprotectExecutable = "/usr/bin/xprotect"
    public static let softwareUpdatePreferences = URL(fileURLWithPath: "/Library/Preferences/com.apple.SoftwareUpdate.plist")

    private let runner: SoftwareCommandRunning
    private let xprotectInfo: URL
    private let softwareUpdatePreferences: URL

    public init(
        runner: SoftwareCommandRunning = NativeSoftwareCommandRunner(),
        xprotectInfo: URL = SecurityPostureService.xprotectInfo,
        softwareUpdatePreferences: URL = SecurityPostureService.softwareUpdatePreferences
    ) {
        self.runner = runner
        self.xprotectInfo = xprotectInfo
        self.softwareUpdatePreferences = softwareUpdatePreferences
    }

    /// Reads each protection with unprivileged commands; a failed read is reported as unknown.
    public func checks() -> [SecurityCheck] {
        let firewall = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        var checks = [
            check(.fileVault, "FileVault disk encryption", SoftwareCommand("/usr/bin/fdesetup", arguments: ["status"]),
                  parse: SecurityPostureParser.fileVault),
            check(.firewall, "Firewall", SoftwareCommand(firewall, arguments: ["--getglobalstate"]),
                  parse: SecurityPostureParser.firewall),
            check(.stealthMode, "Firewall stealth mode", SoftwareCommand(firewall, arguments: ["--getstealthmode"]),
                  parse: SecurityPostureParser.stealthMode, recommendedOn: false),
            check(.gatekeeper, "Gatekeeper", SoftwareCommand("/usr/sbin/spctl", arguments: ["--status"]),
                  parse: SecurityPostureParser.gatekeeper),
            check(.systemIntegrity, "System Integrity Protection", SoftwareCommand("/usr/bin/csrutil", arguments: ["status"]),
                  parse: SecurityPostureParser.systemIntegrity)
        ]
        if let result = try? runner.run(SoftwareCommand(Self.xprotectExecutable, arguments: ["version"])), result.succeeded,
           let version = SecurityPostureParser.xprotectCommandVersion(result.output + "\n" + result.error) {
            checks.append(SecurityCheck(id: .xprotect, title: "XProtect malware definitions", state: .enabled,
                                        detail: "Version \(version)"))
        } else if let version = SecurityPostureParser.xprotectVersion(Self.plist(at: xprotectInfo)) {
            checks.append(SecurityCheck(id: .xprotect, title: "XProtect malware definitions", state: .enabled,
                                        detail: "Version \(version), from the XProtect bundle"))
        } else {
            checks.append(SecurityCheck(id: .xprotect, title: "XProtect malware definitions", state: .unknown,
                                        detail: "The XProtect bundle version could not be read."))
        }
        let responses = SecurityPostureParser.securityResponses(Self.plist(at: softwareUpdatePreferences))
        checks.append(SecurityCheck(id: .securityResponses, title: "Automatic security responses",
                                    state: responses.0, detail: responses.1))
        return checks
    }

    /// The last time macOS completed a Software Update check, when recorded.
    public func lastSuccessfulUpdateCheck() -> Date? {
        Self.plist(at: softwareUpdatePreferences)?["LastSuccessfulDate"] as? Date
    }

    private func check(
        _ id: SecurityCheckID, _ title: String, _ command: SoftwareCommand,
        parse: (String) -> SecurityCheckState, recommendedOn: Bool = true
    ) -> SecurityCheck {
        do {
            let result = try runner.run(command)
            let text = (result.output + "\n" + result.error).trimmingCharacters(in: .whitespacesAndNewlines)
            let state = parse(text)
            let detail = state == .unknown
                ? "Unrecognized \(command.displayString) output (status \(result.status)): \(text.isEmpty ? "no output" : text)"
                : text.components(separatedBy: .newlines).first ?? text
            return SecurityCheck(id: id, title: title, state: state, detail: detail, recommendedOn: recommendedOn)
        } catch {
            return SecurityCheck(id: id, title: title, state: .unknown, detail: error.localizedDescription,
                                 recommendedOn: recommendedOn)
        }
    }

    private static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
