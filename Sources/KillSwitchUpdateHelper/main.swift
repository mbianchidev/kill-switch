import Darwin
import Foundation
import InstallCore

func log(_ message: String) {
    fputs("\(ISO8601DateFormatter().string(from: Date())) [UpdateHelper] \(message)\n", stderr)
}

guard CommandLine.arguments.count == 3,
      let parentPID = Int32(CommandLine.arguments[2]),
      parentPID > 1, parentPID == getppid() else {
    log("Usage: KillSwitchUpdateHelper <transaction.json> <parent-pid>")
    exit(2)
}

var update: AppBundleUpdate?
var parentExited = false
var ready = false
var lockFD: Int32 = -1

do {
    let prepared = try AppBundleUpdate.readManifest(at: URL(fileURLWithPath: CommandLine.arguments[1]))
    update = prepared
    let resultURL = AppBundleUpdateResult.defaultURL
    try FileManager.default.createDirectory(
        at: resultURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let lockURL = resultURL.deletingLastPathComponent().appendingPathComponent("update.lock")
    lockFD = open(lockURL.path, O_CREAT | O_WRONLY | O_NOFOLLOW, 0o600)
    guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        throw AppBundleUpdateError.invalid("Another app update is running, or its lock could not be opened.")
    }
    ready = true
    FileHandle.standardOutput.write(Data("READY\n".utf8))
    try AppBundleUpdate.waitForProcessExit(pid: parentPID)
    parentExited = true
    try prepared.install(relaunch: {
        try AppBundleUpdateResult(version: prepared.version, errorMessage: nil).write(to: resultURL)
        try CommandRunner.runChecked("/usr/bin/open", arguments: ["-n", prepared.destination.path])
    }, log: log)
    log("Installed \(prepared.version) and relaunched \(prepared.destination.path)")
    close(lockFD)
    exit(0)
} catch {
    log(error.localizedDescription)
    if ready, let update {
        let preserveBackup: Bool
        if let updateError = error as? AppBundleUpdateError, case .rollback = updateError {
            preserveBackup = true
        } else {
            preserveBackup = false
        }
        if !preserveBackup {
            do { try update.discard() }
            catch { log("Could not clean the failed staged update: \(error.localizedDescription)") }
        }
        do {
            try AppBundleUpdateResult(version: update.version, errorMessage: error.localizedDescription)
                .write(to: AppBundleUpdateResult.defaultURL)
        } catch {
            log("Could not record the failed update: \(error.localizedDescription)")
        }
        if parentExited {
            do {
                try CommandRunner.runChecked("/usr/bin/open", arguments: [
                    "-n", update.destination.path, "--args", "-KillSwitchFailedUpdateVersion", update.version
                ])
            } catch {
                log("Could not relaunch the app after the update failure: \(error.localizedDescription)")
            }
        }
    }
    if lockFD >= 0 { close(lockFD) }
    exit(1)
}
