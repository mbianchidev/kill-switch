import Darwin
import Foundation
import InstallCore

enum AppBundleUpdater {
    static func start(
        from diskImage: URL,
        version: String,
        appURL: URL,
        logURL: URL,
        log: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void
    ) throws -> Process {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent(
            "KillSwitch-update-mount-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var mounted = false
        var update: AppBundleUpdate?
        var handedOff = false
        defer {
            if !handedOff, let update {
                do { try update.discard() }
                catch { log("Could not remove staged update at \(update.directory.path): \(error.localizedDescription)") }
            }
            if mounted {
                do {
                    try CommandRunner.runChecked("/usr/bin/hdiutil", arguments: ["detach", "-quiet", mount.path])
                    mounted = false
                } catch {
                    log("Could not unmount update image at \(mount.path): \(error.localizedDescription)")
                }
            }
            if !mounted {
                do { try fm.removeItem(at: mount) }
                catch { log("Could not remove update mount directory: \(error.localizedDescription)") }
            }
        }

        try CommandRunner.runChecked("/usr/bin/hdiutil", arguments: [
            "attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen",
            "-mountpoint", mount.path, diskImage.path
        ])
        mounted = true
        let prepared = try AppBundleUpdate.prepare(
            from: mount.appendingPathComponent("KillSwitch.app"),
            replacing: appURL,
            version: version
        )
        update = prepared
        try CommandRunner.runChecked("/usr/bin/hdiutil", arguments: ["detach", "-quiet", mount.path])
        mounted = false

        let helper = prepared.directory.appendingPathComponent("KillSwitchUpdateHelper")
        try fm.copyItem(
            at: appURL.appendingPathComponent("Contents/Helpers/KillSwitchUpdateHelper"),
            to: helper
        )
        try CommandRunner.runChecked("/usr/bin/codesign", arguments: ["--verify", "--strict", helper.path])
        let manifest = try prepared.writeManifest()
        let process = try launchHelper(
            helper, manifest: manifest, logURL: logURL, log: log, onFailure: onFailure
        )
        handedOff = true
        return process
    }

    private static func launchHelper(
        _ helper: URL,
        manifest: URL,
        logURL: URL,
        log: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void
    ) throws -> Process {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(logURL.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw UpdateError.installFailed("Could not open the update helper log: \(String(cString: strerror(errno)))")
        }
        let logHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let readiness = Pipe()
        let process = Process()
        process.executableURL = helper
        process.arguments = [manifest.path, String(getpid())]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = readiness
        process.standardError = logHandle
        process.terminationHandler = { task in
            if task.terminationStatus != 0 {
                let message = "The app update helper exited with status \(task.terminationStatus). See \(logURL.path) for details."
                log(message)
                onFailure(message)
            }
        }
        try process.run()
        do {
            try waitUntilReady(readiness.fileHandleForReading)
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        return process
    }

    private static func waitUntilReady(_ handle: FileHandle) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let status = poll(&descriptor, 1, 1_000)
            if status > 0 {
                guard handle.readData(ofLength: 6) == Data("READY\n".utf8) else {
                    throw UpdateError.installFailed("The update helper could not prepare the restart. See killswitch-update.log.")
                }
                return
            }
            if status < 0, errno != EINTR {
                throw UpdateError.installFailed("Could not communicate with the update helper: \(String(cString: strerror(errno)))")
            }
        }
        throw UpdateError.installFailed("The update helper did not become ready within 30 seconds. The current app was not replaced.")
    }
}
