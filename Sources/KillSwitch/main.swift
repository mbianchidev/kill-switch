import Foundation
import Darwin
import SwiftUI

let executableName = URL(fileURLWithPath: CommandLine.arguments[0])
    .lastPathComponent
    .lowercased()

if executableName == "killswitchctl" {
    exit(KillSwitchCLI.run(arguments: Array(CommandLine.arguments.dropFirst())))
} else {
    KillSwitchApp.main()
}
