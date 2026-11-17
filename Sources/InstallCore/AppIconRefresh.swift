import CoreServices
import Foundation

/// macOS caches application icons by bundle path. When an app is replaced in place, by an update
/// or a reinstall, the Dock, Finder, and Launchpad can keep showing the previous icon. Once per
/// bundled icon, the app marks its bundle as changed and asks Launch Services to register it again.
public struct AppIconRefresh {
    public static let defaultsKey = "appIcon.refreshedFingerprint"

    public typealias Registrar = (URL) -> OSStatus

    public static let launchServicesRegistrar: Registrar = { url in
        LSRegisterURL(url as CFURL, true)
    }

    public let bundleURL: URL
    private let fileManager: FileManager
    private let register: Registrar
    private let now: () -> Date

    public init(
        bundleURL: URL, fileManager: FileManager = .default,
        register: @escaping Registrar = AppIconRefresh.launchServicesRegistrar, now: @escaping () -> Date = Date.init
    ) {
        self.bundleURL = bundleURL
        self.fileManager = fileManager
        self.register = register
        self.now = now
    }

    public var iconURL: URL {
        bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns")
    }

    /// Identifies the bundled icon and version, so a new release or a rebuilt icon refreshes again.
    /// Nil outside an app bundle or when the icon cannot be read.
    public func fingerprint(version: String) -> String? {
        guard AppDistribution(bundleURL: bundleURL) == .appBundle,
              let attributes = try? fileManager.attributesOfItem(atPath: iconURL.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(version)|\(size.int64Value)|\(Int64(modified.timeIntervalSince1970))"
    }

    public static func needsRefresh(fingerprint: String?, refreshed: String?) -> Bool {
        guard let fingerprint else { return false }
        return fingerprint != refreshed
    }

    /// Updates the bundle's modification date, which icon caches compare, then registers it with
    /// Launch Services. A bundle owned by another user cannot be touched; registration still runs
    /// and that failure is returned as a warning. Throws only when registration fails.
    @discardableResult
    public func refresh() throws -> AppIconRefreshError? {
        var warning: AppIconRefreshError?
        do {
            try fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: bundleURL.path)
        } catch {
            warning = .touchFailed(error.localizedDescription)
        }
        let status = register(bundleURL)
        guard status == noErr else { throw AppIconRefreshError.registrationFailed(status) }
        return warning
    }
}

public enum AppIconRefreshError: LocalizedError, Equatable {
    case touchFailed(String)
    case registrationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .touchFailed(let reason): return "The app bundle could not be marked as changed: \(reason)"
        case .registrationFailed(let status): return "Launch Services did not register the app again (status \(status))."
        }
    }
}
