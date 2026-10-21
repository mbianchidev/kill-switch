import Darwin
import Foundation

public enum AppBundleUpdateError: LocalizedError {
    case invalid(String)
    case unwritable(String)
    case replacement(String)
    case rollback(String)
    case parentStillRunning

    public var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return "Invalid app update: \(message)"
        case .unwritable(let path):
            return "The app installation at \(path) is not writable. Quit and reinstall KillSwitch in a writable Applications folder, such as ~/Applications, then retry."
        case .replacement(let message):
            return "App replacement failed: \(message)"
        case .rollback(let message):
            return "App rollback failed: \(message)"
        case .parentStillRunning:
            return "KillSwitch is still running. The update was not installed."
        }
    }
}

public struct AppBundleUpdate: Codable {
    public let destination: URL
    public let stagedBundle: URL
    public let version: String
    private let previousVersion: String

    public var directory: URL { stagedBundle.deletingLastPathComponent() }

    private static let directoryPrefix = ".KillSwitch-update-"

    public static func prepare(from source: URL, replacing destination: URL, version: String) throws -> Self {
        let current = try validateApp(at: destination)
        try validateWritableDestination(destination)
        _ = try validateApp(at: source, expectedVersion: version)

        let destination = destination.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(destination.lastPathComponent)
        let directory = destination.deletingLastPathComponent()
            .appendingPathComponent(directoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let update = Self(
            destination: destination,
            stagedBundle: directory.appendingPathComponent("KillSwitch.app", isDirectory: true),
            version: version,
            previousVersion: current.version
        )
        do {
            try CommandRunner.runChecked(
                "/usr/bin/ditto",
                arguments: ["--noqtn", source.path, update.stagedBundle.path]
            )
            try update.validate()
            try CommandRunner.runChecked(
                "/usr/bin/xattr",
                arguments: ["-dr", "com.apple.quarantine", update.stagedBundle.path]
            )
            return update
        } catch {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch let cleanupError {
                throw AppBundleUpdateError.invalid(
                    "\(error.localizedDescription) Staging cleanup also failed: \(cleanupError.localizedDescription)"
                )
            }
            throw error
        }
    }

    public func writeManifest() throws -> URL {
        try validate()
        let url = directory.appendingPathComponent("transaction.json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        return url
    }

    public static func readManifest(at url: URL) throws -> Self {
        let update = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard url.lastPathComponent == "transaction.json",
              url.deletingLastPathComponent().standardizedFileURL == update.directory else {
            throw AppBundleUpdateError.invalid("The update manifest is outside its staging directory.")
        }
        try update.validate()
        return update
    }

    public func validate() throws {
        try validateLayout()
        try Self.validateWritableDestination(destination)
        _ = try Self.validateApp(at: destination, expectedVersion: previousVersion)
        _ = try Self.validateApp(at: stagedBundle, expectedVersion: version)
    }

    public func install(relaunch: () throws -> Void, log: (String) -> Void) throws {
        try validate()
        var preserveBackup = false
        defer {
            if !preserveBackup {
                do { try discard() }
                catch { log("Update staging cleanup failed at \(directory.path): \(error.localizedDescription)") }
            }
        }

        try swapBundles()
        do {
            try relaunch()
        } catch {
            do {
                try swapBundles()
            } catch let rollbackError {
                preserveBackup = true
                throw AppBundleUpdateError.rollback(
                    "\(error.localizedDescription) \(rollbackError.localizedDescription) Previous app preserved at \(stagedBundle.path)."
                )
            }
            throw AppBundleUpdateError.replacement(
                "Relaunch failed; rolled back to the previous app. \(error.localizedDescription)"
            )
        }
    }

    public func discard() throws {
        if !FileManager.default.fileExists(atPath: directory.path) { return }
        try validateLayout()
        try FileManager.default.removeItem(at: directory)
    }

    public static func waitForProcessExit(pid: Int32, timeout: TimeInterval = 60) throws {
        guard pid > 1, timeout >= 0 else {
            throw AppBundleUpdateError.invalid("The updater received an invalid parent process or timeout.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if kill(pid, 0) != 0 {
                if errno == ESRCH { return }
                if errno != EPERM {
                    throw AppBundleUpdateError.invalid("Could not inspect the previous KillSwitch process.")
                }
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw AppBundleUpdateError.parentStillRunning
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func validateLayout() throws {
        let suffix = String(directory.lastPathComponent.dropFirst(Self.directoryPrefix.count))
        guard destination.isFileURL, stagedBundle.isFileURL,
              destination == destination.standardizedFileURL,
              stagedBundle == stagedBundle.standardizedFileURL,
              destination.pathExtension.lowercased() == "app",
              stagedBundle.lastPathComponent == "KillSwitch.app",
              directory.lastPathComponent.hasPrefix(Self.directoryPrefix),
              UUID(uuidString: suffix) != nil,
              directory.deletingLastPathComponent() == destination.deletingLastPathComponent() else {
            throw AppBundleUpdateError.invalid("The staged app is not a private sibling of the installed app.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw AppBundleUpdateError.invalid("The staging directory is not private to the current user.")
        }
    }

    private func swapBundles() throws {
        let status = destination.path.withCString { destinationPath in
            stagedBundle.path.withCString { stagedPath in
                renameatx_np(AT_FDCWD, destinationPath, AT_FDCWD, stagedPath, UInt32(RENAME_SWAP))
            }
        }
        guard status == 0 else {
            throw AppBundleUpdateError.replacement(String(cString: strerror(errno)))
        }
    }

    private static func validateWritableDestination(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let values = try url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        guard values.volumeIsReadOnly != true,
              FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: url.path) else {
            throw AppBundleUpdateError.unwritable(url.path)
        }
    }

    private static func validateApp(at url: URL, expectedVersion: String? = nil) throws -> Metadata {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard url.pathExtension.lowercased() == "app",
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw AppBundleUpdateError.invalid("\(url.path) is not an app directory, or is a symlink.")
        }
        let metadata = try PropertyListDecoder().decode(
            Metadata.self,
            from: Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        )
        guard metadata.identifier == "io.killswitch.app",
              metadata.packageType == "APPL",
              metadata.executable == "KillSwitch",
              !metadata.version.isEmpty else {
            throw AppBundleUpdateError.invalid("The app identity or executable does not match KillSwitch.")
        }
        if let expectedVersion, metadata.version != expectedVersion {
            throw AppBundleUpdateError.invalid("Expected \(expectedVersion), found \(metadata.version) at \(url.path).")
        }
        let executable = url.appendingPathComponent("Contents/MacOS/KillSwitch")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AppBundleUpdateError.invalid("The app executable is missing or not executable.")
        }
        try CommandRunner.runChecked("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", url.path])
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        try CommandRunner.runChecked("/usr/bin/lipo", arguments: [executable.path, "-verify_arch", architecture])
        return metadata
    }

    private struct Metadata: Decodable {
        let identifier: String
        let packageType: String
        let executable: String
        let version: String

        enum CodingKeys: String, CodingKey {
            case identifier = "CFBundleIdentifier"
            case packageType = "CFBundlePackageType"
            case executable = "CFBundleExecutable"
            case version = "KillSwitchVersion"
        }
    }
}

public struct AppBundleUpdateResult: Codable, Equatable {
    public let version: String
    public let errorMessage: String?

    public init(version: String, errorMessage: String?) {
        self.version = version
        self.errorMessage = errorMessage
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KillSwitch/LastUpdate.json")
    }

    public func allowsAutomaticUpdate(to candidate: String) -> Bool {
        errorMessage == nil || candidate != version
    }

    public static func read(from url: URL) throws -> Self? {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
