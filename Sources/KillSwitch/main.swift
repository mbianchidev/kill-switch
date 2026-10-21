import Foundation
import Darwin
import SwiftUI
import DevCleanupCore
import InstallCore

let executableName = URL(fileURLWithPath: CommandLine.arguments[0])
    .lastPathComponent
    .lowercased()

if executableName == "killswitchctl" {
    exit(KillSwitchCLI.run(arguments: Array(CommandLine.arguments.dropFirst())))
} else {
    if AppDistribution(bundleURL: Bundle.main.bundleURL) == .appBundle {
        UserDefaults.standard.addSuite(named: DevCleanupDefaults.preferenceDomain)
    }
    KillSwitchApp.main()
}
