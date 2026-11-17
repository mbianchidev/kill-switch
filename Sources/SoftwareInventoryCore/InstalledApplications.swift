import Foundation

/// How Gatekeeper assessed an application. Anything not notarized, from the Mac App Store,
/// or from Apple is reported as local.
public enum ApplicationTrust: Equatable, Sendable {
    case notarized
    case appStore
    case apple
    case local(String)
    /// The assessment could not tell, for example because Gatekeeper is disabled.
    case unverified(String)

    public var title: String {
        switch self {
        case .notarized: return "Notarized"
        case .appStore: return "App Store"
        case .apple: return "Apple"
        case .local: return "Local"
        case .unverified: return "Unverified"
        }
    }

    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    public var detail: String {
        switch self {
        case .notarized: return "Developer ID signed and notarized by Apple."
        case .appStore: return "Distributed through the Mac App Store."
        case .apple: return "Part of macOS or signed by Apple."
        case .local(let reason), .unverified(let reason): return reason
        }
    }
}

public enum GatekeeperAssessment {
    public static func command(for path: String) -> SoftwareCommand {
        SoftwareCommand("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", "-vv", path])
    }

    /// Classifies `spctl --assess -vv` output, which macOS writes to standard error.
    public static func classify(status: Int32, output: String) -> ApplicationTrust {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let source = lines.first { $0.hasPrefix("source=") }.map { String($0.dropFirst("source=".count)) }
        let accepted = lines.contains { $0.hasSuffix(": accepted") }
        let rejected = lines.contains { $0.hasSuffix(": rejected") || $0.contains(": rejected (") }

        if lines.contains(where: { $0.hasPrefix("override=") && $0.contains("security disabled") }) {
            return .unverified("Gatekeeper assessments are disabled, so notarization was not checked.")
        }
        if accepted, let source {
            if source.localizedCaseInsensitiveContains("Unnotarized") {
                return .local("Signed with Developer ID but not notarized.")
            }
            if source.localizedCaseInsensitiveContains("Notarized") { return .notarized }
            if source.localizedCaseInsensitiveContains("Mac App Store") { return .appStore }
            if source.hasPrefix("Apple") { return .apple }
            if source.localizedCaseInsensitiveContains("Developer ID") {
                return .local("Signed with Developer ID but not notarized.")
            }
            return .local("Gatekeeper accepted it from an unrecognized source: \(source).")
        }
        if rejected {
            if let source {
                return .local("Gatekeeper rejected it (\(source)); it is not notarized.")
            }
            return .local("Gatekeeper rejected it; it is unsigned, ad-hoc signed, or not notarized.")
        }
        let message = lines.last { !$0.isEmpty } ?? "spctl exited with status \(status)"
        return .unverified("Gatekeeper could not assess it: \(message)")
    }
}

public struct InstalledApplication: Identifiable, Equatable, Sendable {
    public var id: String { path }

    public let path: String
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?
    public let modificationDate: Date?

    public init(path: String, name: String, bundleIdentifier: String?, version: String?, modificationDate: Date?) {
        self.path = path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.modificationDate = modificationDate
    }
}

public struct ApplicationScanResult: Equatable, Sendable {
    public let applications: [InstalledApplication]
    public let failures: [String]
}

/// Lists application bundles in the user-visible Applications folders without opening them.
public struct ApplicationScanner: Sendable {
    public let roots: [URL]
    public let maximumDepth: Int

    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    public init(roots: [URL] = ApplicationScanner.defaultRoots(), maximumDepth: Int = 3) {
        self.roots = roots
        self.maximumDepth = max(1, maximumDepth)
    }

    public func scan(fileManager: FileManager = .default) -> ApplicationScanResult {
        var applications: [String: InstalledApplication] = [:]
        var failures: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        for root in roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    failures.append("\(url.path): \(error.localizedDescription)")
                    return true
                }
            ) else {
                failures.append("\(root.path): the folder could not be listed.")
                continue
            }
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                    enumerator.skipDescendants()
                    let standardized = url.standardizedFileURL
                    applications[standardized.path] = Self.application(at: standardized)
                } else if enumerator.level >= maximumDepth {
                    enumerator.skipDescendants()
                }
            }
        }
        let sorted = applications.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return ApplicationScanResult(applications: sorted, failures: failures)
    }

    static func application(at url: URL) -> InstalledApplication {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: plistURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        } ?? [:]
        func string(_ key: String) -> String? {
            (info[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return InstalledApplication(
            path: url.path,
            name: string("CFBundleDisplayName") ?? string("CFBundleName") ?? url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: string("CFBundleIdentifier"),
            version: string("CFBundleShortVersionString") ?? string("CFBundleVersion"),
            modificationDate: modified
        )
    }
}

public struct ApplicationTrustService: Sendable {
    private let runner: SoftwareCommandRunning

    public init(runner: SoftwareCommandRunning = NativeSoftwareCommandRunner()) {
        self.runner = runner
    }

    public func assess(_ application: InstalledApplication) -> ApplicationTrust {
        do {
            let result = try runner.run(GatekeeperAssessment.command(for: application.path))
            return GatekeeperAssessment.classify(status: result.status, output: result.error + "\n" + result.output)
        } catch {
            return .unverified("Gatekeeper could not be run: \(error.localizedDescription)")
        }
    }
}
