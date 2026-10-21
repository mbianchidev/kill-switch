import Darwin
import Foundation
import InstallCore

struct BundleUpdateChecks {
    private var failures: [String] = []

    mutating func run(root: URL) throws -> [String] {
        try checkWholeBundleReplacement(root: root)
        try checkRollback(root: root)
        try checkPreservedBackup(root: root)
        try checkInvalidDownloads(root: root)
        try checkProtectedDestinations(root: root)
        try checkChangedDestination(root: root)
        try checkInvalidManifest(root: root)
        try checkUpdateResults(root: root)
        try checkParentWait()
        return failures
    }

    private mutating func checkWholeBundleReplacement(root: URL) throws {
        let directory = root.appendingPathComponent("Applications with spaces")
        let installed = try fixture(in: directory, name: "Installed", version: "v1.0.0", marker: "old-only")
        let downloaded = try fixture(in: root, name: "Downloaded", version: "v1.0.1", marker: "new-only")
        let cli = root.appendingPathComponent("mock-killswitchctl")
        let executable = installed.appendingPathComponent("Contents/MacOS/KillSwitch")
        try FileManager.default.createSymbolicLink(at: cli, withDestinationURL: executable)
        try CommandRunner.runChecked(
            "/usr/bin/xattr",
            arguments: ["-w", "com.apple.quarantine", "0083;00000000;MockDownloader;", downloaded.path]
        )

        let update = try AppBundleUpdate.prepare(from: downloaded, replacing: installed, version: "v1.0.1")
        let manifest = try update.writeManifest()
        let restored = try AppBundleUpdate.readManifest(at: manifest)
        check(restored.destination == update.destination, "update manifest retains the exact installed app path")
        check(
            try CommandRunner.run("/usr/bin/xattr", arguments: [
                "-p", "com.apple.quarantine", update.stagedBundle.path
            ]).status != 0,
            "verified update staging does not propagate download quarantine"
        )
        var relaunched = false
        try restored.install(relaunch: {
            relaunched = true
        }, log: { _ in })
        check(relaunched, "whole-bundle replacement relaunches the new app")
        check(try version(at: installed) == "v1.0.1", "the installed bundle reports the downloaded version")
        check(
            FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/Resources/new-only").path),
            "new app resources are installed"
        )
        check(
            !FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/Resources/old-only").path),
            "obsolete app resources are not merged into the new bundle"
        )
        check(
            try FileManager.default.destinationOfSymbolicLink(atPath: cli.path) == executable.path,
            "the optional CLI symlink still targets the same app executable path"
        )
        check(!FileManager.default.fileExists(atPath: update.directory.path), "successful updates remove their staging and backup")
        try CommandRunner.runChecked("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", installed.path])
    }

    private mutating func checkRollback(root: URL) throws {
        let installed = try fixture(in: root, name: "Rollback", version: "v2.0.0")
        let downloaded = try fixture(in: root, name: "Rollback-download", version: "v2.0.1")
        let update = try AppBundleUpdate.prepare(from: downloaded, replacing: installed, version: "v2.0.1")
        do {
            try update.install(relaunch: { throw MockError.launchFailed }, log: { _ in })
            failures.append("a relaunch failure was reported as a successful update")
        } catch {
            check(error.localizedDescription.contains("rolled back"), "relaunch failure reports rollback explicitly")
        }
        check(try version(at: installed) == "v2.0.0", "failed relaunch restores the complete previous app")
        check(!FileManager.default.fileExists(atPath: update.directory.path), "successful rollback cleans staged files")
        try CommandRunner.runChecked("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", installed.path])
    }

    private mutating func checkInvalidDownloads(root: URL) throws {
        let installed = try fixture(in: root, name: "Protected-installed", version: "v3.0.0")
        let wrongVersion = try fixture(in: root, name: "Wrong-version", version: "v2.0.0")
        let wrongIdentity = try fixture(
            in: root, name: "Wrong-identity", version: "v3.0.1", identifier: "example.mock.unrelated"
        )
        let damaged = try fixture(in: root, name: "Damaged", version: "v3.0.1", marker: "sealed-resource")
        try Data("tampered mock data".utf8).write(
            to: damaged.appendingPathComponent("Contents/Resources/sealed-resource")
        )
        for source in [wrongVersion, wrongIdentity, damaged] {
            do {
                let update = try AppBundleUpdate.prepare(from: source, replacing: installed, version: "v3.0.1")
                try update.discard()
                failures.append("invalid downloaded app was accepted: \(source.lastPathComponent)")
            } catch {
                check(try version(at: installed) == "v3.0.0", "invalid updates leave the installed app untouched")
            }
        }
    }

    private mutating func checkPreservedBackup(root: URL) throws {
        let installed = try fixture(in: root, name: "Live-replacement", version: "v8.0.0")
        let downloaded = try fixture(in: root, name: "Live-replacement-download", version: "v8.0.1")
        let update = try AppBundleUpdate.prepare(from: downloaded, replacing: installed, version: "v8.0.1")
        defer {
            do { try update.discard() }
            catch { fputs("Could not clean the mock preserved backup: \(error)\n", stderr) }
        }
        do {
            try update.install(relaunch: {
                throw AppBundleUpdateError.replacementStillRunning(424242)
            }, log: { _ in })
            failures.append("a replacement that could not be stopped was reported as successful")
        } catch {
            check(try version(at: installed) == "v8.0.1", "a live replacement is not swapped out underneath its process")
            check(try version(at: update.stagedBundle) == "v8.0.0", "the previous app is preserved for manual recovery")
        }
    }

    private mutating func checkProtectedDestinations(root: URL) throws {
        let installed = try fixture(in: root, name: "Real-destination", version: "v4.0.0")
        let downloaded = try fixture(in: root, name: "Protected-download", version: "v4.0.1")
        let link = root.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: installed)
        do {
            let update = try AppBundleUpdate.prepare(from: downloaded, replacing: link, version: "v4.0.1")
            try update.discard()
            failures.append("an app-bundle symlink was accepted as an update destination")
        } catch {
            check(try version(at: installed) == "v4.0.0", "update validation preserves a symlink's target")
        }

        if geteuid() != 0 {
            let directory = root.appendingPathComponent("Read-only Applications")
            let protected = try fixture(in: directory, name: "Protected", version: "v4.0.0")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            defer {
                do {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
                } catch {
                    fputs("Could not restore mock directory permissions: \(error)\n", stderr)
                }
            }
            do {
                let update = try AppBundleUpdate.prepare(from: downloaded, replacing: protected, version: "v4.0.1")
                try update.discard()
                failures.append("a read-only installation folder was accepted")
            } catch {
                check(error.localizedDescription.contains("writable"), "non-writable installs get actionable instructions")
            }
        }
    }

    private mutating func checkChangedDestination(root: URL) throws {
        let installed = try fixture(in: root, name: "Concurrent-installed", version: "v5.0.0")
        let downloaded = try fixture(in: root, name: "Concurrent-download", version: "v5.0.1")
        let update = try AppBundleUpdate.prepare(from: downloaded, replacing: installed, version: "v5.0.1")
        defer {
            do { try update.discard() }
            catch { fputs("Could not clean mock staged update: \(error)\n", stderr) }
        }
        let replacement = try fixture(in: root, name: "Concurrent-newer", version: "v5.0.2")
        try FileManager.default.removeItem(at: installed)
        try FileManager.default.moveItem(at: replacement, to: installed)
        do {
            try update.validate()
            failures.append("an installation changed after staging was accepted")
        } catch {
            check(try version(at: installed) == "v5.0.2", "another installed version is not overwritten")
        }
    }

    private mutating func checkUpdateResults(root: URL) throws {
        let path = root.appendingPathComponent("mock-state/LastUpdate.json")
        check(try AppBundleUpdateResult.read(from: path) == nil, "a missing previous update result is normal")
        let failed = AppBundleUpdateResult(version: "v6.0.1", errorMessage: "Mock relaunch failure")
        try failed.write(to: path)
        check(try AppBundleUpdateResult.read(from: path) == failed, "update failures survive the app restart")
        check(!failed.allowsAutomaticUpdate(to: "v6.0.1"), "a failed version cannot trigger an automatic restart loop")
        check(failed.allowsAutomaticUpdate(to: "v6.0.2"), "a newer release can update automatically after an older failure")
        let success = AppBundleUpdateResult(version: "v6.0.1", errorMessage: nil)
        try success.write(to: path)
        check(try AppBundleUpdateResult.read(from: path) == success, "successful updates clear the previous failure")
        check(success.allowsAutomaticUpdate(to: "v6.0.2"), "successful updates do not disable automatic updates")
        try Data("not a valid update receipt".utf8).write(to: path)
        do {
            _ = try AppBundleUpdateResult.read(from: path)
            failures.append("a corrupt update result was silently ignored")
        } catch {}
    }

    private mutating func checkInvalidManifest(root: URL) throws {
        let installed = try fixture(in: root, name: "Manifest-installed", version: "v7.0.0")
        let downloaded = try fixture(in: root, name: "Manifest-download", version: "v7.0.1")
        let update = try AppBundleUpdate.prepare(from: downloaded, replacing: installed, version: "v7.0.1")
        defer {
            do { try update.discard() }
            catch { fputs("Could not clean the mock manifest update: \(error)\n", stderr) }
        }
        let manifest = try update.writeManifest()
        guard var contents = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] else {
            throw MockError.invalidFixture
        }
        contents["stagedBundle"] = installed.absoluteString
        try JSONSerialization.data(withJSONObject: contents).write(to: manifest)
        do {
            _ = try AppBundleUpdate.readManifest(at: manifest)
            failures.append("an update manifest pointing outside its private staging directory was accepted")
        } catch {
            check(try version(at: installed) == "v7.0.0", "invalid manifest paths cannot modify the installed app")
        }
    }

    private mutating func checkParentWait() throws {
        do {
            try AppBundleUpdate.waitForProcessExit(pid: getpid(), timeout: 0)
            failures.append("the updater proceeded while its parent was still running")
        } catch {
            check(error.localizedDescription.contains("still running"), "parent-exit timeout is explained")
        }
    }

    private func fixture(
        in root: URL,
        name: String,
        version: String,
        identifier: String = "io.killswitch.app",
        marker: String? = nil
    ) throws -> URL {
        let app = root.appendingPathComponent("\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        try FileManager.default.copyItem(at: executable, to: macOS.appendingPathComponent("KillSwitch"))
        let metadata: [String: String] = [
            "CFBundleIdentifier": identifier,
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "KillSwitch",
            "CFBundleVersion": String(version.dropFirst()),
            "CFBundleShortVersionString": String(version.dropFirst()),
            "KillSwitchVersion": version
        ]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if let marker {
            try Data("mock resource".utf8).write(to: resources.appendingPathComponent(marker))
        }
        try CommandRunner.runChecked("/usr/bin/codesign", arguments: ["--force", "--sign", "-", app.path])
        return app
    }

    private func version(at app: URL) throws -> String {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let metadata = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let version = metadata["KillSwitchVersion"] else {
            throw MockError.invalidFixture
        }
        return version
    }

    private mutating func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    private enum MockError: Error {
        case launchFailed
        case invalidFixture
    }
}
