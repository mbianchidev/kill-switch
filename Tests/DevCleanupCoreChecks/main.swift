import Foundation
import Darwin
import DevCleanupCore

struct CheckRunner {
    private var failures = 0

    mutating func run() -> Int32 {
        checkParser()
        checkPreferences()
        checkLegacyMigration()
        checkCleanupService()

        if failures == 0 {
            print("All DevCleanupCore checks passed.")
            return 0
        }
        fputs("\(failures) DevCleanupCore check(s) failed.\n", stderr)
        return 1
    }

    private mutating func checkParser() {
        check(
            (try? DevCleanupCLIParser.parse(["dev-cleanup", "status", "--json"])) == .status,
            "parses status"
        )
        check(
            (try? DevCleanupCLIParser.parse([
                "dev-cleanup", "sync-ports",
                "--ports", "41001, 41000,41001",
                "--json",
                "--source", " Porto "
            ])) == .syncPorts(source: "porto", ports: [41000, 41001]),
            "normalizes sync ports"
        )
        check(
            (try? DevCleanupCLIParser.parse([
                "dev-cleanup", "sync-ports",
                "--source=porto",
                "--ports=",
                "--json"
            ])) == .syncPorts(source: "porto", ports: []),
            "parses empty ports as clear"
        )
        checkThrows("rejects invalid source") {
            _ = try DevCleanupCLIParser.parse([
                "dev-cleanup", "sync-ports",
                "--source", "../porto",
                "--ports", "41000",
                "--json"
            ])
        }
        checkThrows("rejects invalid port") {
            _ = try DevCleanupCLIParser.parse([
                "dev-cleanup", "sync-ports",
                "--source", "porto",
                "--ports", "0,41000",
                "--json"
            ])
        }
        checkThrows("requires JSON flag") {
            _ = try DevCleanupCLIParser.parse(["dev-cleanup", "cleanup"])
        }
    }

    private mutating func checkPreferences() {
        let suiteName = "DevCleanupCoreChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = DevCleanupPreferences(defaults: defaults)

        preferences.setAutoKillEnabled(false)
        preferences.setUserPorts([3000, 41000, 3000])
        do {
            try preferences.setIntegrationPorts(
                source: " Porto ",
                ports: [41001, 41000, 41001]
            )
        } catch {
            fail("persists integration ports: \(error.localizedDescription)")
            return
        }

        var settings = preferences.load()
        check(!settings.autoKillEnabled, "loads persisted auto-kill mode")
        check(settings.userPorts == [3000, 41000], "preserves normalized user ports")
        check(
            settings.integrationPorts == ["porto": [41000, 41001]],
            "stores source-owned integration ports separately"
        )
        check(
            settings.effectivePorts == [3000, 41000, 41001],
            "merges effective ports"
        )
        do {
            let response = DevCleanupPortsResponse(version: "dev", settings: settings)
            let data = try JSONEncoder().encode(response)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            check(json?["autoKillEnabled"] as? Bool == false, "encodes auto-kill mode in ports response")
        } catch {
            fail("encodes ports response: \(error.localizedDescription)")
        }

        do {
            try preferences.setIntegrationPorts(source: "porto", ports: [])
        } catch {
            fail("clears integration ports: \(error.localizedDescription)")
            return
        }
        settings = preferences.load()
        check(settings.userPorts == [3000, 41000], "clear preserves user ports")
        check(settings.integrationPorts.isEmpty, "clear removes integration source")

        checkThrows("rejects invalid persisted integration port") {
            try preferences.setIntegrationPorts(source: "porto", ports: [65536])
        }

        do {
            try preferences.setIntegrationPorts(source: "porto", ports: [41001])
            preferences.resetToDefaults()
            settings = preferences.load()
            check(settings.integrationPorts.isEmpty, "reset clears integration ports")
            check(settings.effectivePorts == DevCleanupDefaults.ports, "reset restores effective default ports")
        } catch {
            fail("resets integration ports: \(error.localizedDescription)")
        }
    }

    private mutating func checkLegacyMigration() {
        let targetSuiteName = "DevCleanupCoreChecks.target.\(UUID().uuidString)"
        let legacySuiteName = "DevCleanupCoreChecks.legacy.\(UUID().uuidString)"
        let targetDefaults = UserDefaults(suiteName: targetSuiteName)!
        let legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
        defer {
            targetDefaults.removePersistentDomain(forName: targetSuiteName)
            legacyDefaults.removePersistentDomain(forName: legacySuiteName)
        }

        legacyDefaults.set(false, forKey: "devcleanup.autoKill")
        legacyDefaults.set([3200, 3100], forKey: "devcleanup.ports")
        let preferences = DevCleanupPreferences(
            defaults: targetDefaults,
            legacyDefaults: legacyDefaults
        )
        let settings = preferences.load()
        check(!settings.autoKillEnabled, "migrates legacy auto-kill mode")
        check(settings.userPorts == [3100, 3200], "migrates legacy user ports")
    }

    private mutating func checkCleanupService() {
        let processes = [
            DevCleanupProcess(
                pid: 101, user: "me", elapsedSeconds: 7_200,
                command: "/usr/local/bin/node vite --port 41000"
            ),
            DevCleanupProcess(
                pid: 102, user: "me", elapsedSeconds: 60,
                command: "/usr/local/bin/node vite --port 41001"
            ),
            DevCleanupProcess(
                pid: 103, user: "other", elapsedSeconds: 7_200,
                command: "/usr/local/bin/node vite"
            ),
            DevCleanupProcess(
                pid: 104, user: "me", elapsedSeconds: 7_200,
                command: "/usr/local/bin/node copilot vite"
            )
        ]
        var terminated: [Int32] = []
        let service = DevCleanupService(
            username: "me",
            processProvider: { processes },
            listeningPortsProvider: { [101: [41000], 102: [41001]] },
            terminator: {
                terminated.append($0)
                return true
            }
        )
        let configuration = DevCleanupConfiguration(
            autoKillEnabled: true,
            ageThresholdSeconds: 3_600,
            effectivePorts: [41000, 41001],
            runtimes: ["node"],
            indicators: ["vite"],
            exclusions: ["copilot"]
        )

        do {
            let result = try service.cleanup(configuration: configuration)
            check(result.candidateCount == 2, "counts eligible candidates")
            check(terminated == [101], "kills only stale eligible processes")
            check(result.killed.map(\.pid) == [101], "reports killed process details")
            check(
                result.portProcesses.map(\.port) == [41000, 41001],
                "uses effective watched ports"
            )
        } catch {
            fail("runs shared cleanup: \(error.localizedDescription)")
        }

        var disabledTermination = false
        let disabledService = DevCleanupService(
            username: "me",
            processProvider: {
                [
                    DevCleanupProcess(
                        pid: 201, user: "me", elapsedSeconds: 7_200,
                        command: "node vite"
                    )
                ]
            },
            listeningPortsProvider: { [:] },
            terminator: { _ in
                disabledTermination = true
                return true
            }
        )
        let disabledConfiguration = DevCleanupConfiguration(
            autoKillEnabled: false,
            ageThresholdSeconds: 3_600,
            effectivePorts: [],
            runtimes: ["node"],
            indicators: ["vite"],
            exclusions: []
        )

        do {
            let result = try disabledService.cleanup(configuration: disabledConfiguration)
            check(result.candidateCount == 1, "counts candidates with auto-kill disabled")
            check(result.killed.isEmpty, "reports no kills with auto-kill disabled")
            check(!disabledTermination, "does not terminate when auto-kill is disabled")
        } catch {
            fail("respects disabled auto-kill: \(error.localizedDescription)")
        }
    }

    private mutating func check(_ condition: Bool, _ name: String) {
        if !condition { fail(name) }
    }

    private mutating func checkThrows(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            fail(name)
        } catch {
        }
    }

    private mutating func fail(_ message: String) {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

var runner = CheckRunner()
exit(runner.run())
