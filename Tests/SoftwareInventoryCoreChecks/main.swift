import Foundation
import SoftwareInventoryCore

struct CheckRunner {
    private var failures = 0
    private let fileManager = FileManager.default

    mutating func run() -> Int32 {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SoftwareInventoryCoreChecks-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try checkHomebrewInventory()
            try checkHomebrewPlans()
            try checkHomebrewService()
            try checkRunningCasks()
            try checkHomebrewLocation(in: root)
            checkGatekeeper()
            try checkApplicationScanner(in: root)
            try checkSoftwareUpdates()
            try checkSecurityPosture(in: root)
        } catch {
            fail("fixture setup: \(error.localizedDescription)")
        }
        if failures == 0 {
            print("All SoftwareInventoryCore checks passed.")
            return 0
        }
        fputs("\(failures) SoftwareInventoryCore check(s) failed.\n", stderr)
        return 1
    }

    private func packages() throws -> [HomebrewPackage] {
        try HomebrewInventoryParser.parse(info: Data(Fixtures.brewInfo.utf8), outdated: Data(Fixtures.brewOutdated.utf8))
    }

    private mutating func checkHomebrewInventory() throws {
        let packages = try packages()
        func package(_ name: String) -> HomebrewPackage? { packages.first { $0.name == name } }
        check(packages.count == 8, "parses every installed formula and cask")
        let tool = package("synthetic-tool")
        check(tool?.isOutdated == true && tool?.installedVersion == "1.0" && tool?.latestVersion == "2.0" && tool?.canUpgrade == true,
              "marks outdated formulae with installed and latest versions")
        check(package("tapped")?.isOutdated == true && package("tapped")?.fullName == "synthetic-owner/tap/tapped",
              "matches outdated tap formulae by full name")
        check(package("current-lib")?.isOutdated == false, "keeps current formulae up to date")
        check(package("pinned-lib")?.canUpgrade == false && package("pinned-lib")?.installedOnRequest == false,
              "pinned formulae are not upgradable")
        check(package("self-updater")?.autoUpdates == true && package("self-updater")?.canUpgrade == false,
              "self-updating casks are never upgradable, even when listed as outdated")
        check(package("latest-app")?.isUnversionedCask == true && package("latest-app")?.canUpgrade == false,
              "unversioned casks are not upgradable")
        let apps = HomebrewInventoryParser.casksByApplicationPath(packages)
        check(apps["/Applications/Plain App.app"]?.name == "plain-app" && apps["/Applications/Renamed.app"]?.name == "renamed-app"
              && apps["/Applications/Self Updater.app"] != nil && apps.count == 3,
              "maps cask application targets, including renamed legacy artifacts")
        check((try? HomebrewInventoryParser.parse(info: Data("not json".utf8), outdated: Data(Fixtures.brewOutdated.utf8))) == nil,
              "rejects malformed inventory output")
    }

    private mutating func checkHomebrewPlans() throws {
        let packages = try packages()
        let brew = HomebrewInstallation(executable: "/synthetic/homebrew/bin/brew")
        let plan = try HomebrewCommandPlanner.upgradeAll(packages, installation: brew, running: [])
        check(plan.map(\.arguments) == [
            ["upgrade", "--formula", "synthetic-owner/tap/tapped", "synthetic-tool"],
            ["upgrade", "--cask", "plain-app"]
        ], "upgrade all names only upgradable formulae and casks, skipping self-updating casks")
        check((try? HomebrewCommandPlanner.upgradeAll(packages, installation: brew, running: ["plain-app"]))?.map(\.arguments)
              == [["upgrade", "--formula", "synthetic-owner/tap/tapped", "synthetic-tool"]], "upgrade all skips running casks")
        check((try? HomebrewCommandPlanner.upgradeAll(packages, installation: brew, running: nil))?.allSatisfy { !$0.arguments.contains("--cask") } == true,
              "unknown running state skips every cask")
        check(plan.allSatisfy { $0.executable == brew.executable && $0.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1"
                && $0.environment["PATH"]?.hasPrefix("/synthetic/homebrew/bin:") == true },
              "brew commands use the located executable without implicit metadata updates")
        func rejectsUpgrade(_ name: String) -> Bool {
            guard let package = packages.first(where: { $0.name == name }) else { return false }
            return (try? HomebrewCommandPlanner.upgrade(package, installation: brew, running: [])) == nil
        }
        check(rejectsUpgrade("self-updater") && rejectsUpgrade("pinned-lib") && rejectsUpgrade("latest-app") && rejectsUpgrade("current-lib"),
              "single upgrades refuse self-updating, pinned, unversioned, and current packages")
        if let cask = packages.first(where: { $0.name == "plain-app" }) {
            check((try? HomebrewCommandPlanner.upgrade(cask, installation: brew, running: []))?.arguments == ["upgrade", "--cask", "plain-app"],
                  "plans a single cask upgrade")
            check((try? HomebrewCommandPlanner.upgrade(cask, installation: brew, running: ["plain-app"])) == nil
                  && (try? HomebrewCommandPlanner.upgrade(cask, installation: brew, running: nil)) == nil,
                  "a single cask upgrade refuses a running or unknown-state app")
            check((try? HomebrewCommandPlanner.uninstall(cask, installation: brew))?.arguments == ["uninstall", "--cask", "plain-app"],
                  "uninstall never forces, zaps, or ignores dependencies")
        }
        let hostile = HomebrewPackage(kind: .formula, name: "--force", fullName: "--force", displayName: "--force",
                                      summary: nil, installedVersion: "1", latestVersion: "2", isOutdated: true)
        check((try? HomebrewCommandPlanner.uninstall(hostile, installation: brew)) == nil
              && (try? HomebrewCommandPlanner.upgradeAll([hostile], installation: brew, running: [])) == nil,
              "refuses option-like package names")
        check((try? HomebrewCommandPlanner.upgradeAll(packages.filter { !$0.canUpgrade }, installation: brew, running: [])) == nil,
              "reports when nothing can be upgraded")
    }

    private mutating func checkRunningCasks() throws {
        let packages = try packages()
        let brew = HomebrewInstallation(executable: "/synthetic/homebrew/bin/brew")
        let ids: (String) -> String? = { $0.hasSuffix("Plain App.app") ? "com.example.plain" : nil }
        func running(_ paths: [String]?, _ bundles: Set<String>?) -> Set<String>? {
            RunningCaskDetector.runningCasks(packages, installation: brew, processPaths: paths, runningBundleIDs: bundles, bundleIdentifier: ids)
        }
        check(running(["/Applications/Plain App.app/Contents/MacOS/Plain"], []) == ["plain-app"], "a process inside the app bundle marks its cask running")
        check(running(["/synthetic/homebrew/Caskroom/renamed-app/4.0/helper"], []) == ["renamed-app"], "a process from the Caskroom marks its cask running")
        check(running([], ["com.example.plain"]) == ["plain-app"], "a running bundle identifier marks its cask running")
        check(running(["/Applications/Plain App Helper.app/x"], []) == [], "a similarly named app is not a match")
        check(running(nil, []) == nil && running([], nil) == nil, "unreadable process lists leave running state unknown")
        let quit = try HomebrewInventoryParser.parse(
            info: Data(#"{"formulae": [], "casks": [{"token": "q", "installed": "1", "artifacts": [{"uninstall": [{"quit": ["com.example.q", "com.example.q.helper"]}, {"quit": "com.example.q2"}]}]}]}"#.utf8),
            outdated: Data(#"{"formulae": [], "casks": []}"#.utf8)
        )
        check(quit.first?.quitBundleIDs == ["com.example.q", "com.example.q.helper", "com.example.q2"], "reads uninstall quit bundle identifiers")
        let runner = MockRunner { _ in SoftwareCommandResult(status: 0, output: "ok", error: "") }
        let commands = [brew.command(["upgrade", "--cask", "a"]), brew.command(["upgrade", "--cask", "b"])]
        let transcript = HomebrewService(installation: brew, runner: runner).perform(commands) { $0.arguments.last == "a" ? "a is running" : nil }
        check(runner.commands.map { $0.arguments.last } == ["b"] && transcript.failure == nil && transcript.text.contains("Skipped"),
              "a cask that starts running before its turn is skipped, not upgraded")
    }

    private mutating func checkHomebrewService() throws {
        let brew = HomebrewInstallation(executable: "/synthetic/homebrew/bin/brew")
        let runner = MockRunner { command in
            if command.arguments.first == "info" { return SoftwareCommandResult(status: 0, output: Fixtures.brewInfo, error: "") }
            return SoftwareCommandResult(status: 0, output: Fixtures.brewOutdated, error: "")
        }
        check((try? HomebrewService(installation: brew, runner: runner).loadPackages())?.count == 8, "loads the inventory through brew")
        let failing = MockRunner { _ in SoftwareCommandResult(status: 1, output: "", error: "Error: synthetic failure") }
        do {
            _ = try HomebrewService(installation: brew, runner: failing).loadPackages()
            fail("reports brew inventory failures")
        } catch {
            check(error.localizedDescription.contains("synthetic failure"), "surfaces brew error output")
        }
        let partial = MockRunner { command in
            command.arguments.contains("--formula")
                ? SoftwareCommandResult(status: 1, output: "Upgrading synthetic-tool", error: "Error: synthetic upgrade failure")
                : SoftwareCommandResult(status: 0, output: "ok", error: "")
        }
        let plan = try HomebrewCommandPlanner.upgradeAll(try packages(), installation: brew, running: [])
        let transcript = HomebrewService(installation: brew, runner: partial).perform(plan)
        check(partial.commands.count == 1 && transcript.failure?.contains("synthetic upgrade failure") == true
              && transcript.text.contains("Upgrading synthetic-tool"),
              "stops at the first failed command and keeps its transcript")
        let unlaunchable = MockRunner { _ in throw SyntheticFailure() }
        check(HomebrewService(installation: brew, runner: unlaunchable).perform(plan).failure == "synthetic launch failure",
              "reports commands that cannot launch")
    }

    private mutating func checkHomebrewLocation(in root: URL) throws {
        let executable = root.appendingPathComponent("homebrew/bin/brew")
        let plain = root.appendingPathComponent("plain/bin/brew")
        for url in [executable, plain] {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        let missing = root.appendingPathComponent("missing/bin/brew").path
        check(HomebrewInstallation.locate(candidates: [missing, plain.path, executable.path])?.executable == executable.path,
              "locates only an executable brew")
        check(HomebrewInstallation.locate(candidates: [missing, plain.path]) == nil, "reports Homebrew as absent")
        check(HomebrewInstallation(executable: executable.path).prefix == root.appendingPathComponent("homebrew").path,
              "derives the Homebrew prefix")
    }

    private mutating func checkGatekeeper() {
        func trust(_ output: String, status: Int32 = 0) -> ApplicationTrust {
            GatekeeperAssessment.classify(status: status, output: output)
        }
        check(trust("/A.app: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Synthetic") == .notarized,
              "recognizes notarized apps")
        check(trust("/A.app: accepted\nsource=Mac App Store\norigin=Apple Mac OS Application Signing") == .appStore,
              "recognizes Mac App Store apps")
        check(trust("/A.app: accepted\nsource=Apple System\norigin=macOS Software Signing") == .apple, "recognizes Apple apps")
        check(trust("/A.app: rejected", status: 3).isLocal, "ad-hoc or unsigned apps are local")
        check(trust("/A.app: rejected\nsource=Unnotarized Developer ID", status: 3).isLocal, "unnotarized Developer ID apps are local")
        check(trust("/A.app: accepted\nsource=Developer ID\norigin=Developer ID Application: Synthetic").isLocal,
              "accepted but unnotarized Developer ID apps are local")
        if case .unverified = trust("/A.app: accepted\noverride=security disabled") {} else {
            fail("disabled Gatekeeper leaves apps unverified")
        }
        if case .unverified = trust("spctl: synthetic internal error", status: 1) {} else {
            fail("unrecognized assessment output is unverified, not local")
        }
        let runner = MockRunner { _ in SoftwareCommandResult(status: 3, output: "", error: "/A.app: rejected\n") }
        let app = InstalledApplication(path: "/synthetic/A.app", name: "A", bundleIdentifier: nil, version: nil, modificationDate: nil)
        check(ApplicationTrustService(runner: runner).assess(app).isLocal
              && runner.commands.first?.arguments == ["--assess", "--type", "execute", "-vv", "/synthetic/A.app"],
              "assesses apps with spctl standard error output")
    }

    private mutating func checkApplicationScanner(in root: URL) throws {
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try makeApp(applications.appendingPathComponent("Synthetic.app"), info: [
            "CFBundleName": "Synthetic", "CFBundleDisplayName": "Synthetic Display",
            "CFBundleIdentifier": "com.example.synthetic", "CFBundleShortVersionString": "1.2.3"
        ])
        try makeApp(applications.appendingPathComponent("Synthetic.app/Contents/Helpers/Helper.app"), info: ["CFBundleName": "Helper"])
        try makeApp(applications.appendingPathComponent("Suite/Nested.app"), info: nil)
        try makeApp(applications.appendingPathComponent("Suite/Deep/Deeper/TooDeep.app"), info: nil)
        let result = ApplicationScanner(
            roots: [applications, root.appendingPathComponent("Missing", isDirectory: true)], maximumDepth: 3
        ).scan()
        let names = result.applications.map(\.name)
        check(names == ["Nested", "Synthetic Display"], "lists top-level and nested apps without app internals or deep folders")
        let synthetic = result.applications.first { $0.name == "Synthetic Display" }
        check(synthetic?.bundleIdentifier == "com.example.synthetic" && synthetic?.version == "1.2.3",
              "reads bundle identifiers and versions")
        check(result.failures.isEmpty, "ignores missing application folders")
    }

    private func makeApp(_ url: URL, info: [String: String]?) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
        if let info {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
    }

    private mutating func checkSoftwareUpdates() throws {
        let list = SoftwareUpdateParser.parse(output: Fixtures.softwareUpdate, error: "", currentMajorVersion: 26)
        let categories = list.items.map(\.category)
        check(categories == [.safari, .macOSUpdate, .macOSUpgrade, .securityResponse, .other],
              "classifies Safari, same-major macOS, major upgrades, security responses, and other software")
        check(list.items.map(\.category.isSecurityRelevant) == [true, true, false, true, false],
              "highlights only security-relevant updates")
        check(list.items[1].requiresRestart && list.items[1].sizeKiB == 3_181_896 && list.items[1].version == "26.9.1"
              && !list.items[0].requiresRestart, "reads restart, size, and version fields")
        check(list.items[4].title == "Command Line Tools for Xcode, Beta" && !list.items[4].recommended,
              "keeps commas inside update titles")
        check(list.warnings == ["The software update request was denied as another process is busy."],
              "reports scan problems as readable warnings")
        check(SoftwareUpdateParser.parse(output: "Software Update Tool\n\nFinding available software\n", error: "No new software available.\n",
                                         currentMajorVersion: 26) == SoftwareUpdateList(items: [], warnings: []),
              "no available software is an empty list, not a warning")
        let runner = MockRunner { _ in SoftwareCommandResult(status: 1, output: "", error: "synthetic softwareupdate failure") }
        check((try? SoftwareUpdateService(runner: runner).list(scan: false, currentMajorVersion: 26)) == nil
              && runner.commands.first?.arguments == ["--list", "--no-scan"],
              "fails visibly when softwareupdate fails and reuses the last scan by default")
    }

    private mutating func checkSecurityPosture(in root: URL) throws {
        check(SecurityPostureParser.fileVault("FileVault is On.") == .enabled
              && SecurityPostureParser.fileVault("FileVault is Off.") == .disabled
              && SecurityPostureParser.fileVault("Encryption in progress: Percent completed = 40") == .enabled,
              "reads FileVault status")
        check(SecurityPostureParser.firewall("Firewall is enabled. (State = 1)") == .enabled
              && SecurityPostureParser.firewall("Firewall is blocking all non-essential incoming connections. (State = 2)") == .enabled
              && SecurityPostureParser.firewall("Firewall is disabled. (State = 0)") == .disabled,
              "reads firewall state")
        check(SecurityPostureParser.stealthMode("Firewall stealth mode is on") == .enabled
              && SecurityPostureParser.stealthMode("Firewall stealth mode is off") == .disabled, "reads stealth mode")
        check(SecurityPostureParser.gatekeeper("assessments enabled") == .enabled
              && SecurityPostureParser.gatekeeper("assessments disabled") == .disabled, "reads Gatekeeper status")
        check(SecurityPostureParser.systemIntegrity("System Integrity Protection status: enabled.") == .enabled
              && SecurityPostureParser.systemIntegrity("System Integrity Protection status: disabled.") == .disabled
              && SecurityPostureParser.systemIntegrity("System Integrity Protection status: unknown (Custom Configuration).") == .unknown,
              "reads System Integrity Protection status")
        check(SecurityPostureParser.securityResponses(["CriticalUpdateInstall": false]).0 == .disabled
              && SecurityPostureParser.securityResponses([:]).0 == .unknown,
              "unset automatic security responses are unknown, not assumed on")

        let xprotect = root.appendingPathComponent("XProtect-Info.plist")
        let preferences = root.appendingPathComponent("SoftwareUpdate.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "9999"], format: .xml, options: 0)
            .write(to: xprotect)
        try PropertyListSerialization.data(fromPropertyList: ["CriticalUpdateInstall": true], format: .xml, options: 0)
            .write(to: preferences)
        let runner = MockRunner { command in
            switch command.executable {
            case "/usr/bin/fdesetup": return SoftwareCommandResult(status: 0, output: "FileVault is On.\n", error: "")
            case "/usr/sbin/spctl": return SoftwareCommandResult(status: 0, output: "", error: "assessments enabled\n")
            case "/usr/bin/csrutil": throw SyntheticFailure()
            default:
                return command.arguments == ["--getglobalstate"]
                    ? SoftwareCommandResult(status: 0, output: "Firewall is disabled. (State = 0)\n", error: "")
                    : SoftwareCommandResult(status: 0, output: "unexpected synthetic output\n", error: "")
            }
        }
        let checks = Dictionary(uniqueKeysWithValues: SecurityPostureService(
            runner: runner, xprotectInfo: xprotect, softwareUpdatePreferences: preferences
        ).checks().map { ($0.id, $0) })
        check(checks.count == SecurityCheckID.allCases.count, "reports every security check")
        check(checks[.fileVault]?.state == .enabled && checks[.gatekeeper]?.state == .enabled, "reads standard output and standard error")
        check(checks[.firewall]?.needsAttention == true, "flags a disabled firewall")
        check(checks[.stealthMode]?.state == .unknown && checks[.stealthMode]?.needsAttention == false
              && checks[.stealthMode]?.detail.contains("unexpected synthetic output") == true,
              "reports unrecognized output as unknown with the raw text")
        check(checks[.systemIntegrity]?.state == .unknown && checks[.systemIntegrity]?.detail == "synthetic launch failure",
              "reports commands that cannot run")
        check(checks[.xprotect]?.detail == "Version 9999" && checks[.securityResponses]?.state == .enabled,
              "reads XProtect and automatic security response settings")
        let missing = SecurityPostureService(
            runner: runner, xprotectInfo: root.appendingPathComponent("missing.plist"),
            softwareUpdatePreferences: root.appendingPathComponent("missing.plist")
        ).checks()
        check(missing.first { $0.id == .xprotect }?.state == .unknown && missing.first { $0.id == .securityResponses }?.state == .unknown,
              "missing plists are unknown")
    }

    private mutating func check(_ condition: Bool, _ name: String) {
        if !condition { fail(name) }
    }

    private mutating func fail(_ message: String) {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

var runner = CheckRunner()
exit(runner.run())
