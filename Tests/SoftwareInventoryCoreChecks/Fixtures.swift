import Foundation
import SoftwareInventoryCore

/// Records commands and answers them from a synthetic handler; never launches a process.
final class MockRunner: SoftwareCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SoftwareCommand] = []
    private let handler: (SoftwareCommand) throws -> SoftwareCommandResult

    init(_ handler: @escaping (SoftwareCommand) throws -> SoftwareCommandResult) {
        self.handler = handler
    }

    var commands: [SoftwareCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ command: SoftwareCommand) throws -> SoftwareCommandResult {
        lock.lock()
        recorded.append(command)
        lock.unlock()
        return try handler(command)
    }
}

struct SyntheticFailure: LocalizedError {
    var errorDescription: String? { "synthetic launch failure" }
}

enum Fixtures {
    static let brewInfo = #"""
    {
      "formulae": [
        {"name": "synthetic-tool", "full_name": "synthetic-tool", "desc": "Synthetic tool",
         "installed": [{"version": "1.0", "installed_on_request": true}], "linked_keg": "1.0",
         "pinned": false, "outdated": true, "versions": {"stable": "2.0"}, "deprecated": false, "disabled": false},
        {"name": "pinned-lib", "full_name": "pinned-lib", "desc": null,
         "installed": [{"version": "3.0", "installed_on_request": false}], "linked_keg": "3.0",
         "pinned": true, "outdated": true, "versions": {"stable": "3.1"}},
        {"name": "tapped", "full_name": "synthetic-owner/tap/tapped",
         "installed": [{"version": "0.1"}], "pinned": false, "versions": {"stable": "0.2"}},
        {"name": "current-lib", "full_name": "current-lib",
         "installed": [{"version": "5.0"}], "linked_keg": "5.0", "versions": {"stable": "5.0"}}
      ],
      "casks": [
        {"token": "self-updater", "full_token": "self-updater", "name": ["Self Updater"], "installed": "1.0",
         "version": "2.0", "auto_updates": true,
         "artifacts": [{"app": ["Self Updater.app"], "target": "/Applications/Self Updater.app"}]},
        {"token": "plain-app", "full_token": "plain-app", "name": ["Plain App"], "installed": "1.0",
         "version": "1.1", "auto_updates": null,
         "artifacts": [{"binary": ["/synthetic/bin/plain"], "target": "/synthetic/bin/plain"},
                       {"app": ["Plain App.app"], "target": "/Applications/Plain App.app"}]},
        {"token": "renamed-app", "full_token": "renamed-app", "name": ["Renamed"], "installed": "4.0",
         "version": "4.0", "artifacts": [{"app": ["Source.app", {"target": "Renamed.app"}]}]},
        {"token": "latest-app", "full_token": "latest-app", "name": ["Latest"], "installed": "latest",
         "version": "latest", "artifacts": [{"uninstall": [{"quit": "synthetic.latest"}]}]}
      ]
    }
    """#

    static let brewOutdated = #"""
    {
      "formulae": [
        {"name": "synthetic-tool", "installed_versions": ["1.0"], "current_version": "2.0", "pinned": false},
        {"name": "pinned-lib", "installed_versions": ["3.0"], "current_version": "3.1", "pinned": true},
        {"name": "synthetic-owner/tap/tapped", "installed_versions": ["0.1"], "current_version": "0.2", "pinned": false}
      ],
      "casks": [
        {"name": "self-updater", "installed_versions": ["1.0"], "current_version": "2.0"},
        {"name": "plain-app", "installed_versions": ["1.0"], "current_version": "1.1"},
        {"name": "latest-app", "installed_versions": ["latest"], "current_version": "latest"}
      ]
    }
    """#

    static let softwareUpdate = """
    Software Update Tool

    Scan finished with error: Error Domain=SUMacControllerError Code=7507 "Busy" UserInfo={NSLocalizedDescription=The software update request was denied as another process is busy.}
    Software Update found the following new or updated software:
    * Label: Safari99.1Synthetic-99.1
    \tTitle: Safari, Version: 99.1, Size: 250130KiB, Recommended: YES,\u{20}
    * Label: macOS Synthetic 26.9.1-25Z001
    \tTitle: macOS Synthetic 26.9.1, Version: 26.9.1, Size: 3181896KiB, Recommended: YES, Action: restart,\u{20}
    * Label: macOS 27.0-26A001
    \tTitle: macOS 27.0, Version: 27.0, Size: 11188054KiB, Recommended: YES, Action: restart,\u{20}
    * Label: Background Security Improvement 26.9.1 (a)-25Z001a
    \tTitle: Background Security Improvement, Version: 26.9.1 (a), Size: 1024KiB, Recommended: YES, Action: restart,\u{20}
    * Label: Command Line Tools for Xcode-99.0
    \tTitle: Command Line Tools for Xcode, Beta, Version: 99.0, Size: 700000KiB, Recommended: NO,\u{20}
    """
}
