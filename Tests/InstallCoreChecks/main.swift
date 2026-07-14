import Foundation
import Darwin
import InstallCore

struct InstallCoreCheckRunner {
    private var failures = 0

    mutating func run() -> Int32 {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallCoreChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try checkDirectoryPreservation(root: root)
            try checkRegularBinaryReplacement(root: root)
            try checkSymlinkReplacement(root: root)
            try checkDanglingSymlinkReplacement(root: root)
            try checkManagedPathProtection(root: root)
        } catch {
            fail("unexpected setup error: \(error.localizedDescription)")
        }

        if failures == 0 {
            print("InstallCoreChecks: all checks passed")
            return 0
        }
        fputs("\(failures) InstallCore check(s) failed.\n", stderr)
        return 1
    }

    private mutating func checkDirectoryPreservation(root: URL) throws {
        let path = root.appendingPathComponent("KillSwitch-directory")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        do {
            try InstallPathSafety.removeReplaceableBinaryIfPresent(at: path.path)
            fail("replaceable binary accepted a real directory")
        } catch {
            check(
                error.localizedDescription ==
                    "Refusing to replace directory at \(path.path). Move it before updating KillSwitch.",
                "directory error text is clear and unwrapped"
            )
        }
        var isDirectory: ObjCBool = false
        check(
            FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "real install directory is preserved"
        )
    }

    private mutating func checkRegularBinaryReplacement(root: URL) throws {
        let path = root.appendingPathComponent("KillSwitch-file")
        try Data("old".utf8).write(to: path)
        try InstallPathSafety.removeReplaceableBinaryIfPresent(at: path.path)
        check(!FileManager.default.fileExists(atPath: path.path), "regular binary is removable")
    }

    private mutating func checkSymlinkReplacement(root: URL) throws {
        let target = root.appendingPathComponent("symlink-target")
        let link = root.appendingPathComponent("KillSwitch-symlink")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try InstallPathSafety.removeReplaceableBinaryIfPresent(at: link.path)
        check(
            FileManager.default.fileExists(atPath: target.path),
            "removing install symlink preserves its directory target"
        )
        check(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil,
            "install symlink is removed"
        )
    }

    private mutating func checkDanglingSymlinkReplacement(root: URL) throws {
        let link = root.appendingPathComponent("KillSwitch-dangling")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: root.appendingPathComponent("missing").path
        )
        try InstallPathSafety.removeReplaceableBinaryIfPresent(at: link.path)
        check(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil,
            "dangling install symlink is removed"
        )
    }

    private mutating func checkManagedPathProtection(root: URL) throws {
        let path = root.appendingPathComponent("killswitchctl")
        try Data("user-owned".utf8).write(to: path)
        do {
            try InstallPathSafety.removeManagedSymbolicLinkIfPresent(at: path.path)
            fail("managed path removed a regular file")
        } catch {
            check(
                error.localizedDescription ==
                    "Refusing to remove non-symlink at \(path.path). Move it before installing or uninstalling KillSwitch.",
                "managed-path error text is clear"
            )
        }
        check(
            FileManager.default.fileExists(atPath: path.path),
            "managed path preserves a regular file"
        )
    }

    private mutating func check(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    private mutating func fail(_ message: String) {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

var runner = InstallCoreCheckRunner()
exit(runner.run())
