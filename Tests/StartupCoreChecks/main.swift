import Darwin
import Foundation
import StartupCore

@main
struct StartupCoreChecks {
    private static var failures: [String] = []
    private static var count = 0

    static func main() {
        checkCronDocuments()
        checkLaunchServiceSafety()
        checkBackgroundItems()
        checkServiceOperations()
        checkCronAndLoginOperations()
        if failures.isEmpty {
            print("StartupCoreChecks: \(count) checks passed")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            fputs("StartupCoreChecks: \(failures.count) of \(count) checks failed\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func checkCronDocuments() {
        let text = """
        # Example only
        SHELL=/bin/sh
        PATH = /usr/bin:/bin

        */5 * * * * /usr/bin/printf '%s\\n' 'example job'
        @reboot /usr/bin/true
        """
        let document = CronDocument(text: text)
        check(document.jobs.count == 2, "cron ignores comments, environment, and blank lines")
        check(document.jobs.first?.schedule == "*/5 * * * *", "cron keeps the complete schedule")
        check(document.jobs.last?.schedule == "@reboot", "cron supports macro schedules")
        do {
            guard let job = document.jobs.first else { check(false, "cron job exists"); return }
            let disabled = try document.setting(job: job, enabled: false)
            check(disabled.contains("# KillSwitch disabled: */5"), "cron disabling comments only the selected job")
            check(disabled.contains("PATH = /usr/bin:/bin"), "cron disabling preserves environment exactly")
            check(!disabled.hasSuffix("\n"), "cron edits preserve the original trailing newline")
            let disabledDocument = CronDocument(text: disabled)
            check(disabledDocument.jobs.first?.enabled == false, "disabled cron jobs remain visible")
            let restored = try disabledDocument.setting(job: disabledDocument.jobs[0], enabled: true)
            check(restored == text, "enabling a cron job restores the exact original document")
            do {
                _ = try CronDocument(text: text + "\n@hourly /usr/bin/true").setting(job: job, enabled: false)
                check(false, "stale cron documents are refused")
            } catch { check(true, "stale cron documents are refused") }
        } catch { check(false, "cron edit: \(error.localizedDescription)") }
        check(CronDocument(text: "@unknown /usr/bin/true\nnot a cron entry").jobs.isEmpty, "malformed cron rows are not editable")
        let duplicate = CronDocument(text: "@reboot /usr/bin/true\n@reboot /usr/bin/true\n")
        check(Set(duplicate.jobs.map(\.id)).count == 2, "duplicate cron commands keep distinct identities")
    }

    private static func checkLaunchServiceSafety() {
        let user = LaunchService(
            label: "org.example.worker", url: URL(fileURLWithPath: "/tmp/example.plist"),
            domain: .gui(501), program: "/Applications/Example.app/Contents/MacOS/worker"
        )
        do {
            let disable = try StartupCommandPlanner.launchService(user, enabled: false, currentUID: 501)
            check(disable.executable == "/bin/launchctl", "launch services use launchctl")
            check(disable.arguments == ["disable", "gui/501/org.example.worker"], "user service targets the current GUI domain")
            check(!disable.administrator, "user service does not request administrator privileges")
            var daemon = user
            daemon.domain = .system
            let root = try StartupCommandPlanner.launchService(daemon, enabled: false, currentUID: 501)
            check(root.arguments == ["disable", "system/org.example.worker"] && root.administrator, "system services require authorization")
            let enable = try StartupCommandPlanner.launchService(user, enabled: true, currentUID: 501)
            check(enable.arguments.first == "enable", "service disabling is reversible")
            check(!disable.arguments.contains("bootout"), "disabling startup never terminates a running service")
        } catch { check(false, "launchctl planning: \(error.localizedDescription)") }

        for label in ["com.apple.example", "../other", "example/other", "-option", "example\ninjection"] {
            var item = user
            item.label = label
            do {
                _ = try StartupCommandPlanner.launchService(item, enabled: false, currentUID: 501)
                check(false, "protected or malformed label refused: \(label.debugDescription)")
            } catch { check(true, "protected or malformed label refused") }
        }
        var foreign = user
        foreign.domain = .gui(502)
        do {
            _ = try StartupCommandPlanner.launchService(foreign, enabled: false, currentUID: 501)
            check(false, "other accounts' GUI domains are refused")
        } catch { check(true, "other accounts' GUI domains are refused") }
        let apple = LaunchService(
            label: user.label, url: URL(fileURLWithPath: "/System/Library/LaunchAgents/org.example.worker.plist"),
            domain: user.domain, program: user.program
        )
        do {
            _ = try StartupCommandPlanner.launchService(apple, enabled: false, currentUID: 501)
            check(false, "system-protected plists are refused regardless of label")
        } catch { check(true, "system-protected plists are refused regardless of label") }

        do {
            let parsed = try StartupParsers.disabledServices("""
            disabled services = {
                "org.example.enabled" => false
                "org.example.disabled" => true
            }
            """)
            check(parsed["org.example.disabled"] == true, "launchctl disabled overrides are parsed")
            check(parsed["org.example.enabled"] == false, "explicit enabled overrides are parsed")
        } catch { check(false, "disabled services parser: \(error.localizedDescription)") }
        do {
            _ = try StartupParsers.disabledServices("authorization denied")
            check(false, "unreadable launchctl state does not become an enabled default")
        } catch { check(true, "unreadable launchctl state does not become an enabled default") }
    }

    private static func checkBackgroundItems() {
        let text = """
        Records for UID 501:
        UUID: sample-one
        Name: Example helper
        Type: login item (0x4)
        Disposition: [enabled, allowed, visible] (0x7)
        Identifier: org.example.helper
        URL: file:///Applications/Example.app
        UUID: sample-two
        Name: Disabled helper
        Type: app (0x2)
        Disposition: [allowed, visible] (0x6)
        Identifier: org.example.disabled
        URL: file:///Applications/Disabled.app
        Records for UID 502:
        UUID: foreign-item
        Name: Other account item
        Type: login item
        Disposition: [enabled, allowed]
        """
        let items = StartupParsers.backgroundItems(text, currentUID: 501)
        check(items.count == 2, "background items do not mix other user accounts")
        check(items.first?.state == .enabled, "enabled background item disposition is explicit")
        check(items.last?.state == .disabled, "disabled background item disposition is explicit")
        check(items.allSatisfy { $0.restriction != nil }, "modern background items stay managed by macOS settings")
    }

    private static func checkServiceOperations() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("killswitch-startup-check-\(UUID().uuidString)", isDirectory: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { check(false, "remove temporary startup files: \(error.localizedDescription)") }
        }
        do {
            let home = directory.appendingPathComponent("home")
            let agents = home.appendingPathComponent("Library/LaunchAgents")
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            let url = agents.appendingPathComponent("org.example.worker.plist")
            let plist: [String: Any] = [
                "Label": "org.example.worker", "ProgramArguments": ["/usr/bin/true"],
                "RunAtLoad": true
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
            let runner = MockStartupRunner()
            let service = StartupService(
                home: home, currentUID: getuid(), stateDirectory: directory.appendingPathComponent("state"),
                runner: runner
            )
            let item = try service.readLaunchService(at: url, domain: .gui(getuid()), overrides: [:])
            check(item.state == .enabled, "user launch agents are discoverable from synthetic plists")
            try service.setEnabled(false, item: item)
            check(runner.commands.contains {
                $0.arguments == ["disable", "gui/\(getuid())/org.example.worker"]
            }, "service operation executes the exact validated target")
            let untouched = try Data(contentsOf: url)
            check(try PropertyListSerialization.propertyList(from: untouched, format: nil) as? NSDictionary == plist as NSDictionary, "service operation never rewrites launch plists")

            var changed = plist
            changed["Label"] = "org.example.replaced"
            try PropertyListSerialization.data(fromPropertyList: changed, format: .xml, options: 0).write(to: url)
            let calls = runner.commands.count
            do {
                try service.setEnabled(false, item: item)
                check(false, "changed launch service is refused")
            } catch { check(runner.commands.count == calls, "changed launch service is refused before executing commands") }

            let link = agents.appendingPathComponent("linked.plist")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            do {
                _ = try service.readLaunchService(at: link, domain: .gui(getuid()), overrides: [:])
                check(false, "linked launch plists are refused")
            } catch { check(true, "linked launch plists are refused") }

            runner.fail = true
            let current = try service.readLaunchService(at: url, domain: .gui(getuid()), overrides: [:])
            do {
                try service.setEnabled(false, item: current)
                check(false, "launchctl failure must propagate")
            } catch { check(error.localizedDescription.contains("synthetic failure"), "launchctl failure is actionable") }
        } catch { check(false, "startup operations: \(error.localizedDescription)") }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        count += 1
        do {
            if try !condition() { failures.append(message) }
        } catch { failures.append("\(message): \(error.localizedDescription)") }
    }

    private static func checkCronAndLoginOperations() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("killswitch-startup-mock-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: directory) }
                catch { check(false, "remove startup mock state: \(error.localizedDescription)") }
            }
            let runner = MockStartupRunner()
            let service = StartupService(home: directory, currentUID: 501, stateDirectory: directory, runner: runner)
            let original = "# Synthetic fixture\n@reboot /usr/bin/printf '%s' 'example job'\n"
            let document = CronDocument(text: original)
            guard let job = document.jobs.first else { check(false, "synthetic cron job exists"); return }
            let item = StartupItem(
                id: "synthetic-cron", name: job.schedule, kind: .cron, domain: .system,
                command: job.command, origin: "root crontab", state: .enabled, source: .cron(job, .system)
            )
            runner.cronText = original
            runner.installedCron = try document.setting(job: job, enabled: false)
            try service.setEnabled(false, item: item)
            let change = runner.commands.first { $0.executable == "/bin/sh" }
            check(change?.administrator == true, "root cron updates require administrator approval")
            check(change?.arguments.last?.contains("/usr/bin/crontab -u root -") == true, "root cron updates target root explicitly")
            check(change?.arguments.last?.contains("The crontab changed") == true, "cron installation rechecks concurrent changes")
            let backup = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("cron-system-") }
            check(try backup.map { try String(contentsOf: $0, encoding: .utf8) } == original, "cron updates preserve a complete backup")
            if let backup {
                let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
                check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "cron backups are private")
            }
            let count = runner.commands.filter { $0.executable == "/bin/sh" }.count
            do {
                try service.setEnabled(false, item: item)
                check(false, "stale cron operations must fail")
            } catch {
                check(runner.commands.filter { $0.executable == "/bin/sh" }.count == count, "stale cron entries do not execute an update")
            }

            let login = LegacyLoginItem(name: "Example \"quoted\" app", path: "/Applications/Example's app.app", hidden: true)
            runner.loginItems = [login]
            runner.loginToRestore = login
            let loginItem = StartupItem(
                id: login.id, name: login.name, kind: .loginApp, domain: .gui(501),
                command: login.path, origin: "Synthetic login item", state: .enabled, source: .loginItem(login)
            )
            try service.setEnabled(false, item: loginItem)
            check(runner.loginItems?.isEmpty == true, "login disabling removes only the selected legacy registration")
            let saved = try JSONDecoder().decode(
                [LegacyLoginItem].self, from: Data(contentsOf: directory.appendingPathComponent("disabled-login-apps.json"))
            )
            check(saved == [login], "login backups preserve path, name, and hidden state")
            let disabled = StartupItem(
                id: login.id, name: login.name, kind: .loginApp, domain: .gui(501),
                command: login.path, origin: "Synthetic login item", state: .disabled, source: .loginItem(login)
            )
            try service.setEnabled(true, item: disabled)
            check(runner.loginItems == [login], "login app disabling is reversible")
            check(runner.commands.filter { $0.executable == "/usr/bin/osascript" }.allSatisfy { !$0.administrator }, "legacy login app changes never escalate privileges")
        } catch { check(false, "mock cron/login operations: \(error.localizedDescription)") }
    }
}

private final class MockStartupRunner: StartupCommandRunning {
    var commands: [StartupCommand] = []
    var fail = false
    var cronText: String?
    var installedCron: String?
    var loginItems: [LegacyLoginItem]?
    var loginToRestore: LegacyLoginItem?

    func run(_ command: StartupCommand) throws -> StartupCommandResult {
        commands.append(command)
        if fail { return StartupCommandResult(status: 1, output: "", error: "synthetic failure") }
        if command.executable == "/usr/bin/crontab", let cronText {
            return StartupCommandResult(status: 0, output: cronText, error: "")
        }
        if command.executable == "/bin/sh" {
            cronText = installedCron
        }
        if command.executable == "/usr/bin/osascript", let script = command.arguments.last {
            if script.contains("JSON.stringify"), let loginItems {
                return StartupCommandResult(status: 0, output: String(decoding: try JSONEncoder().encode(loginItems), as: UTF8.self), error: "")
            }
            if script.contains("matches[0].delete()") { loginItems = [] }
            if script.contains("app.loginItems.push"), let loginToRestore { loginItems = [loginToRestore] }
        }
        if command.arguments.first == "print-disabled" {
            return StartupCommandResult(
                status: 0, output: "disabled services = {\n\"org.example.worker\" => true\n}", error: ""
            )
        }
        return StartupCommandResult(status: 0, output: "", error: "")
    }
}
