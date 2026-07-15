import Foundation

public enum DevCleanupDefaults {
    public static let preferenceDomain = "KillSwitch"

    public static let ports: [Int] = [
        3000, 3001, 3002, 3003, 4000, 4200, 5000, 5001, 5173, 5174, 5555,
        6006, 8000, 8001, 8080, 8081, 8090, 8443, 8888, 9000, 9090, 9091
    ]

    public static let ageThresholdHours = 12
    public static let portScanSeconds = 5
    public static let cleanupSeconds = 600

    public static let runtimes: [String] = [
        "node", "deno", "bun",
        "npm", "npx", "pnpm", "yarn",
        "python", "python3", "python2",
        "java", "mvn",
        "cargo", "rustc",
        "go", "ruby"
    ]

    public static let indicators: [String] = [
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

    public static let exclusions: [String] = [
        "copilot",
        "mcp", "modelcontextprotocol", "context7", "work_iq", "work-iq", "workiq",
        "fabric", "seismic", "azure", "kusto", "revenue", "server-github",
        "killswitch", "visual studio code", "code helper", "electron", "obsidian",
        "chrome", "slack", "teams", "orbstack", "spotify", "handy",
        "language-server", "language_server", "tsserver", "lsp"
    ]
}

public struct DevCleanupSettings: Equatable {
    public let autoKillEnabled: Bool
    public let ageThresholdHours: Int
    public let portScanIntervalSeconds: Int
    public let cleanupIntervalSeconds: Int
    public let userPorts: [Int]
    public let integrationPorts: [String: [Int]]
    public let runtimes: [String]
    public let indicators: [String]
    public let exclusions: [String]

    public var effectivePorts: [Int] {
        DevCleanupPreferences.normalizedPorts(
            userPorts + integrationPorts.values.flatMap { $0 }
        )
    }

    public var configuration: DevCleanupConfiguration {
        DevCleanupConfiguration(
            autoKillEnabled: autoKillEnabled,
            ageThresholdSeconds: ageThresholdHours * 3600,
            effectivePorts: effectivePorts,
            runtimes: runtimes,
            indicators: indicators,
            exclusions: exclusions
        )
    }
}

public enum DevCleanupPreferenceError: LocalizedError, Equatable {
    case invalidSource(String)
    case invalidPort(Int)
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let source):
            return "Invalid integration source '\(source)'. Use 1-64 lowercase letters, numbers, dots, underscores, or hyphens."
        case .invalidPort(let port):
            return "Invalid port \(port). Ports must be between 1 and 65535."
        case .persistenceFailed:
            return "Could not persist dev-cleanup integration ports."
        }
    }
}

public final class DevCleanupPreferences {
    private enum Key: String, CaseIterable {
        case autoKill = "devcleanup.autoKill"
        case ageHours = "devcleanup.ageHours"
        case portInterval = "devcleanup.portInterval"
        case cleanupInterval = "devcleanup.cleanupInterval"
        case ports = "devcleanup.ports"
        case runtimes = "devcleanup.runtimes"
        case indicators = "devcleanup.indicators"
        case exclusions = "devcleanup.exclusions"
        case integrationPorts = "devcleanup.integrationPorts"
    }

    private let defaults: UserDefaults

    public convenience init() {
        self.init(
            defaults: UserDefaults(suiteName: DevCleanupDefaults.preferenceDomain) ?? .standard,
            legacyDefaults: .standard
        )
    }

    public init(defaults: UserDefaults, legacyDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let legacyDefaults {
            migrateLegacyValues(from: legacyDefaults)
        }
    }

    /// Lightweight read of only the integration-ports dictionary.
    /// Use this on hot timer paths instead of `load()` to avoid a full settings rebuild.
    public func loadIntegrationPorts() -> [String: [Int]] {
        defaults.synchronize()
        return integrationPorts()
    }

    public func load() -> DevCleanupSettings {
        defaults.synchronize()
        return DevCleanupSettings(
            autoKillEnabled: bool(.autoKill, default: true),
            ageThresholdHours: int(.ageHours, default: DevCleanupDefaults.ageThresholdHours),
            portScanIntervalSeconds: int(.portInterval, default: DevCleanupDefaults.portScanSeconds),
            cleanupIntervalSeconds: int(.cleanupInterval, default: DevCleanupDefaults.cleanupSeconds),
            userPorts: Self.normalizedPorts(ints(.ports, default: DevCleanupDefaults.ports)),
            integrationPorts: integrationPorts(),
            runtimes: Self.normalizedEntries(strings(.runtimes, default: DevCleanupDefaults.runtimes)),
            indicators: Self.normalizedEntries(strings(.indicators, default: DevCleanupDefaults.indicators)),
            exclusions: Self.normalizedEntries(strings(.exclusions, default: DevCleanupDefaults.exclusions))
        )
    }

    public func setAutoKillEnabled(_ value: Bool) {
        defaults.set(value, forKey: Key.autoKill.rawValue)
    }

    public func setAgeThresholdHours(_ value: Int) {
        defaults.set(value, forKey: Key.ageHours.rawValue)
    }

    public func setPortScanIntervalSeconds(_ value: Int) {
        defaults.set(value, forKey: Key.portInterval.rawValue)
    }

    public func setCleanupIntervalSeconds(_ value: Int) {
        defaults.set(value, forKey: Key.cleanupInterval.rawValue)
    }

    public func setUserPorts(_ value: [Int]) {
        defaults.set(Self.normalizedPorts(value), forKey: Key.ports.rawValue)
    }

    public func setRuntimes(_ value: [String]) {
        defaults.set(Self.normalizedEntries(value), forKey: Key.runtimes.rawValue)
    }

    public func setIndicators(_ value: [String]) {
        defaults.set(Self.normalizedEntries(value), forKey: Key.indicators.rawValue)
    }

    public func setExclusions(_ value: [String]) {
        defaults.set(Self.normalizedEntries(value), forKey: Key.exclusions.rawValue)
    }

    @discardableResult
    public func setIntegrationPorts(source rawSource: String, ports: [Int]) throws -> DevCleanupSettings {
        let source = try Self.normalizedSource(rawSource)
        if let invalid = ports.first(where: { !(1...65535).contains($0) }) {
            throw DevCleanupPreferenceError.invalidPort(invalid)
        }

        var values = integrationPorts()
        let normalized = Self.normalizedPorts(ports)
        if normalized.isEmpty {
            values.removeValue(forKey: source)
        } else {
            values[source] = normalized
        }
        defaults.set(values, forKey: Key.integrationPorts.rawValue)
        guard defaults.synchronize() else {
            throw DevCleanupPreferenceError.persistenceFailed
        }
        return load()
    }

    public func resetToDefaults() {
        setAutoKillEnabled(true)
        setAgeThresholdHours(DevCleanupDefaults.ageThresholdHours)
        setPortScanIntervalSeconds(DevCleanupDefaults.portScanSeconds)
        setCleanupIntervalSeconds(DevCleanupDefaults.cleanupSeconds)
        setUserPorts(DevCleanupDefaults.ports)
        setRuntimes(DevCleanupDefaults.runtimes)
        setIndicators(DevCleanupDefaults.indicators)
        setExclusions(DevCleanupDefaults.exclusions)
        defaults.removeObject(forKey: Key.integrationPorts.rawValue)
    }

    public static func normalizedPorts(_ ports: [Int]) -> [Int] {
        Array(Set(ports.filter { (1...65535).contains($0) })).sorted()
    }

    public static func normalizedEntries(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    public static func normalizedSource(_ rawSource: String) throws -> String {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard
            (1...64).contains(source.count),
            source.unicodeScalars.allSatisfy({ allowed.contains($0) }),
            source.first?.isLetter == true || source.first?.isNumber == true
        else {
            throw DevCleanupPreferenceError.invalidSource(rawSource)
        }
        return source
    }

    private func integrationPorts() -> [String: [Int]] {
        guard let raw = defaults.dictionary(forKey: Key.integrationPorts.rawValue) else {
            return [:]
        }
        var result: [String: [Int]] = [:]
        for (rawSource, rawPorts) in raw {
            guard let source = try? Self.normalizedSource(rawSource),
                  let values = rawPorts as? [Any] else { continue }
            let ports = values.compactMap { value -> Int? in
                if let int = value as? Int { return int }
                if let number = value as? NSNumber { return number.intValue }
                return nil
            }
            let normalized = Self.normalizedPorts(ports)
            if !normalized.isEmpty {
                result[source] = normalized
            }
        }
        return result
    }

    private func migrateLegacyValues(from legacyDefaults: UserDefaults) {
        guard Key.allCases.allSatisfy({
            defaults.object(forKey: $0.rawValue) == nil
        }) else {
            return
        }

        var migrated = false
        for key in Key.allCases {
            guard let value = legacyDefaults.object(forKey: key.rawValue) else { continue }
            defaults.set(value, forKey: key.rawValue)
            migrated = true
        }
        if migrated {
            defaults.synchronize()
        }
    }

    private func bool(_ key: Key, default fallback: Bool) -> Bool {
        guard defaults.object(forKey: key.rawValue) != nil else { return fallback }
        return defaults.bool(forKey: key.rawValue)
    }

    private func int(_ key: Key, default fallback: Int) -> Int {
        guard defaults.object(forKey: key.rawValue) != nil else { return fallback }
        return defaults.integer(forKey: key.rawValue)
    }

    private func ints(_ key: Key, default fallback: [Int]) -> [Int] {
        guard let values = defaults.array(forKey: key.rawValue) else { return fallback }
        let converted = values.compactMap { value -> Int? in
            if let int = value as? Int { return int }
            if let number = value as? NSNumber { return number.intValue }
            return nil
        }
        return converted.count == values.count ? converted : fallback
    }

    private func strings(_ key: Key, default fallback: [String]) -> [String] {
        guard let values = defaults.array(forKey: key.rawValue) else { return fallback }
        let converted = values.compactMap { $0 as? String }
        return converted.count == values.count ? converted : fallback
    }
}
