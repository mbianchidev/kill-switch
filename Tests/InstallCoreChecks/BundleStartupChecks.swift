import Darwin
import Foundation
import InstallCore

struct BundleStartupChecks {
    private var failures: [String] = []

    mutating func run(root: URL) throws -> [String] {
        try checkAcknowledgements(root: root)
        try checkConfirmedStartup(root: root)
        try checkConfirmationFailure(root: root)
        try checkFailedStartup(root: root, name: "Exited", body: "exit 42")
        try checkFailedStartup(root: root, name: "Crash-after-ack", body: acknowledgement + "\n/bin/sleep 0.1\nexit 42")
        try checkFailedStartup(
            root: root, name: "Wrong-nonce",
            body: "KILLSWITCH_UPDATE_STARTUP_TOKEN=00000000-0000-0000-0000-000000000000\n"
                + acknowledgement + "\nexec /bin/sleep 30"
        )
        try checkUnresponsiveStartup(root: root)
        return failures
    }

    private mutating func checkAcknowledgements(root: URL) throws {
        check(try AppBundleStartupRequest.read(from: [:]) == nil, "normal launches need no update acknowledgement")
        let app = try mockApp(root: root, name: "Acknowledgement", body: "exit 0")
        let directory = try stagingDirectory(root: root)
        let request = AppBundleStartupRequest(directory: directory, bundleURL: app, version: "v9.0.0")
        check(
            try AppBundleStartupRequest.read(from: request.environment)?.token == request.token,
            "startup request survives the child environment"
        )
        check(try !request.isAcknowledged(processIdentifier: getpid()), "startup is not confirmed before an acknowledgement exists")
        do {
            try request.acknowledge(bundleURL: app, version: "v8.0.0")
            failures.append("a different running version acknowledged startup")
        } catch {}
        try request.acknowledge(bundleURL: app, version: "v9.0.0")
        check(try request.isAcknowledged(processIdentifier: getpid()), "matching GUI startup acknowledgement is accepted")
        do {
            _ = try request.isAcknowledged(processIdentifier: 424242)
            failures.append("an acknowledgement from a different process was accepted")
        } catch {}
        var invalid = request.environment
        invalid["KILLSWITCH_UPDATE_STARTUP_FILE"] = root.appendingPathComponent("outside/startup.json").path
        do {
            _ = try AppBundleStartupRequest.read(from: invalid)
            failures.append("a startup receipt outside the private update directory was accepted")
        } catch {}
    }

    private mutating func checkConfirmedStartup(root: URL) throws {
        let app = try mockApp(root: root, name: "Healthy with spaces", body: acknowledgement + "\nexec /bin/sleep 30")
        let directory = try stagingDirectory(root: root)
        var confirmed = false
        let process = try AppBundleRelauncher.launchAndConfirm(
            bundleURL: app, version: "v9.0.0", directory: directory, timeout: 3,
            onConfirmed: { confirmed = true }
        )
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        check(confirmed && process.isRunning, "success is recorded only after the replacement confirms healthy startup")
    }

    private mutating func checkFailedStartup(root: URL, name: String, body: String) throws {
        let app = try mockApp(root: root, name: name, body: body)
        let directory = try stagingDirectory(root: root)
        var confirmed = false
        do {
            let process = try AppBundleRelauncher.launchAndConfirm(
                bundleURL: app, version: "v9.0.0", directory: directory, timeout: 3,
                onConfirmed: { confirmed = true }
            )
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            failures.append("\(name) startup was incorrectly confirmed")
        } catch {
            check(!confirmed, "\(name) cannot write a success result")
        }
    }

    private mutating func checkConfirmationFailure(root: URL) throws {
        let app = try mockApp(root: root, name: "Receipt-write-failure", body: acknowledgement + "\nexec /bin/sleep 30")
        let directory = try stagingDirectory(root: root)
        do {
            let process = try AppBundleRelauncher.launchAndConfirm(
                bundleURL: app, version: "v9.0.0", directory: directory, timeout: 3,
                onConfirmed: { throw CheckError.confirmationWriteFailed }
            )
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            failures.append("a failed success-receipt write was accepted")
        } catch {
            struct Receipt: Decodable { let processIdentifier: Int32 }
            let receipt = try JSONDecoder().decode(
                Receipt.self, from: Data(contentsOf: directory.appendingPathComponent("startup.json"))
            )
            check(
                kill(receipt.processIdentifier, 0) != 0 && errno == ESRCH,
                "the replacement is stopped before rollback when success recording fails"
            )
        }
    }

    private mutating func checkUnresponsiveStartup(root: URL) throws {
        let pidFile = root.appendingPathComponent("mock-unresponsive-pid")
        let body = """
        printf '%s' "$$" > \(CommandRunner.shellQuote(pidFile.path))
        trap '' TERM
        exec /bin/sleep 30
        """
        let app = try mockApp(root: root, name: "Unresponsive", body: body)
        let directory = try stagingDirectory(root: root)
        do {
            let process = try AppBundleRelauncher.launchAndConfirm(
                bundleURL: app, version: "v9.0.0", directory: directory, timeout: 1
            )
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            failures.append("an unresponsive replacement was accepted")
        } catch {
            check(error.localizedDescription.contains("startup"), "startup timeout reports why the update cannot continue")
        }
        let rawPID = try String(contentsOf: pidFile, encoding: .utf8)
        guard let pid = Int32(rawPID) else { throw CheckError.invalidPID }
        check(kill(pid, 0) != 0 && errno == ESRCH, "an unresponsive replacement is fully stopped before rollback")
    }

    private func stagingDirectory(root: URL) throws -> URL {
        let directory = root.appendingPathComponent(".KillSwitch-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func mockApp(root: URL, name: String, body: String) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/KillSwitch")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    private var acknowledgement: String {
        """
        printf '{"token":"%s","processIdentifier":%s,"version":"%s","bundleURL":"%s"}' \
        "$KILLSWITCH_UPDATE_STARTUP_TOKEN" "$$" "$KILLSWITCH_UPDATE_STARTUP_VERSION" \
        "$KILLSWITCH_UPDATE_STARTUP_BUNDLE" > "$KILLSWITCH_UPDATE_STARTUP_FILE"
        """
    }

    private mutating func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    private enum CheckError: Error {
        case invalidPID
        case confirmationWriteFailed
    }
}
