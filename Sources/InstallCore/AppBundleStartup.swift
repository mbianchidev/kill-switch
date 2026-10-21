import Darwin
import Foundation

public struct AppBundleStartupRequest: Equatable {
    public let token: UUID
    public let receiptURL: URL
    public let bundleURL: URL
    public let version: String

    private static let tokenKey = "KILLSWITCH_UPDATE_STARTUP_TOKEN"
    private static let fileKey = "KILLSWITCH_UPDATE_STARTUP_FILE"
    private static let versionKey = "KILLSWITCH_UPDATE_STARTUP_VERSION"
    private static let bundleKey = "KILLSWITCH_UPDATE_STARTUP_BUNDLE"

    public init(directory: URL, bundleURL: URL, version: String) {
        token = UUID()
        receiptURL = directory.appendingPathComponent("startup.json")
        self.bundleURL = bundleURL
        self.version = version
    }

    private init(token: UUID, receiptURL: URL, bundleURL: URL, version: String) {
        self.token = token
        self.receiptURL = receiptURL
        self.bundleURL = bundleURL
        self.version = version
    }

    public var environment: [String: String] {
        [
            Self.tokenKey: token.uuidString,
            Self.fileKey: receiptURL.path,
            Self.versionKey: version,
            Self.bundleKey: bundleURL.absoluteString
        ]
    }

    public static func isRequested(in environment: [String: String]) -> Bool {
        [tokenKey, fileKey, versionKey, bundleKey].contains { environment[$0] != nil }
    }

    public static func read(from environment: [String: String]) throws -> Self? {
        guard isRequested(in: environment) else { return nil }
        guard let rawToken = environment[tokenKey], let token = UUID(uuidString: rawToken),
              let path = environment[fileKey], (path as NSString).isAbsolutePath,
              let version = environment[versionKey], !version.isEmpty,
              let rawBundle = environment[bundleKey], let bundle = URL(string: rawBundle),
              bundle.isFileURL else {
            throw AppBundleUpdateError.invalid("The replacement startup request is incomplete or invalid.")
        }
        let request = Self(token: token, receiptURL: URL(fileURLWithPath: path), bundleURL: bundle, version: version)
        try request.validate()
        return request
    }

    public func acknowledge(bundleURL: URL, version: String) throws {
        try validate()
        guard self.bundleURL.resolvingSymlinksInPath() == bundleURL.resolvingSymlinksInPath(),
              self.version == version else {
            throw AppBundleUpdateError.invalid("The running app does not match the replacement startup request.")
        }
        let acknowledgement = Acknowledgement(
            token: token, processIdentifier: getpid(), version: version, bundleURL: bundleURL
        )
        try JSONEncoder().encode(acknowledgement).write(to: receiptURL, options: .atomic)
    }

    public func isAcknowledged(processIdentifier: Int32) throws -> Bool {
        let acknowledgement: Acknowledgement
        do {
            acknowledgement = try JSONDecoder().decode(Acknowledgement.self, from: Data(contentsOf: receiptURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
        guard acknowledgement.token == token,
              acknowledgement.processIdentifier == processIdentifier,
              acknowledgement.version == version,
              acknowledgement.bundleURL.resolvingSymlinksInPath() == bundleURL.resolvingSymlinksInPath() else {
            throw AppBundleUpdateError.invalid("The replacement startup acknowledgement does not match this update.")
        }
        return true
    }

    func validate() throws {
        guard !version.isEmpty, receiptURL.isFileURL,
              receiptURL.lastPathComponent == "startup.json",
              bundleURL.pathExtension.lowercased() == "app" else {
            throw AppBundleUpdateError.invalid("The replacement startup receipt has an invalid location or version.")
        }
        try AppUpdateStaging.validate(directory: receiptURL.deletingLastPathComponent(), beside: bundleURL)
    }

    private struct Acknowledgement: Codable {
        let token: UUID
        let processIdentifier: Int32
        let version: String
        let bundleURL: URL
    }
}

public enum AppBundleRelauncher {
    @discardableResult
    public static func launchAndConfirm(
        bundleURL: URL,
        version: String,
        directory: URL,
        timeout: TimeInterval = 30,
        onConfirmed: () throws -> Void = {}
    ) throws -> Process {
        guard timeout > 0 else {
            throw AppBundleUpdateError.invalid("The replacement startup timeout must be positive.")
        }
        let request = AppBundleStartupRequest(directory: directory, bundleURL: bundleURL, version: version)
        try request.validate()
        let process = Process()
        process.executableURL = bundleURL.appendingPathComponent("Contents/MacOS/KillSwitch")
        process.currentDirectoryURL = bundleURL.deletingLastPathComponent()
        process.environment = ProcessInfo.processInfo.environment.merging(request.environment) { _, update in update }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()

        do {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var acknowledgedAt: TimeInterval?
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard process.isRunning else {
                    throw AppBundleUpdateError.replacement(
                        "The replacement exited before confirming startup (status \(process.terminationStatus))."
                    )
                }
                if try request.isAcknowledged(processIdentifier: process.processIdentifier) {
                    if acknowledgedAt == nil { acknowledgedAt = ProcessInfo.processInfo.systemUptime }
                    if let acknowledgedAt, ProcessInfo.processInfo.systemUptime - acknowledgedAt >= 0.5 {
                        try onConfirmed()
                        guard process.isRunning else {
                            throw AppBundleUpdateError.replacement("The replacement exited during startup confirmation.")
                        }
                        return process
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw AppBundleUpdateError.replacement("Timed out waiting for replacement GUI startup.")
        } catch {
            try stopReplacement(process)
            throw error
        }
    }

    private static func stopReplacement(_ process: Process) throws {
        if process.isRunning {
            process.terminate()
            waitForTermination(process)
        }
        if process.isRunning {
            if kill(process.processIdentifier, SIGKILL) != 0, errno != ESRCH {
                throw AppBundleUpdateError.replacementStillRunning(process.processIdentifier)
            }
            waitForTermination(process)
        }
        guard !process.isRunning else {
            throw AppBundleUpdateError.replacementStillRunning(process.processIdentifier)
        }
        process.waitUntilExit()
    }

    private static func waitForTermination(_ process: Process) {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
