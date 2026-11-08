import Foundation
import Darwin
import SwiftUI
import DevCleanupCore
import InstallCore

let arguments = Array(CommandLine.arguments.dropFirst())

#if KILLSWITCH_PERFORMANCE_PROBE
guard arguments.first == "--performance-probe" else {
    fputs("The isolated probe requires --performance-probe before its command.\n", stderr)
    exit(2)
}
guard Thread.isMainThread else {
    fputs("The AppKit performance probe must start on the main thread.\n", stderr)
    exit(2)
}
MainActor.assumeIsolated {
    exit(PerformanceProbe.run(arguments: Array(arguments.dropFirst())))
}
#else
let executableName = URL(fileURLWithPath: CommandLine.arguments[0])
    .lastPathComponent
    .lowercased()

if executableName == "killswitchctl" {
    exit(KillSwitchCLI.run(arguments: arguments))
} else {
    let probeOptions: Set<String> = ["--performance-probe", "--probe-identity", "--interface-checks", "--native-health-check"]
    guard !arguments.contains(where: probeOptions.contains) else {
        fputs("Performance probes require a separate KILLSWITCH_PERFORMANCE_PROBE build. The live app was not started.\n", stderr)
        exit(2)
    }
    if AppDistribution(bundleURL: Bundle.main.bundleURL) == .appBundle {
        UserDefaults.standard.addSuite(named: DevCleanupDefaults.preferenceDomain)
    }
    KillSwitchApp.main()
}
#endif
