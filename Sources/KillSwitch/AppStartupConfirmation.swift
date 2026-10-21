import Foundation
import InstallCore

@MainActor
enum AppStartupConfirmation {
    private static var applicationLaunched = false
    private static var contentAppeared = false
    private static var completed = false

    static func applicationDidFinishLaunching() {
        applicationLaunched = true
        confirmIfReady()
    }

    static func contentDidAppear() {
        contentAppeared = true
        confirmIfReady()
    }

    private static func confirmIfReady() {
        guard applicationLaunched, contentAppeared, !completed else { return }
        completed = true
        do {
            guard let request = try AppBundleStartupRequest.read(from: ProcessInfo.processInfo.environment) else { return }
            try request.acknowledge(bundleURL: Bundle.main.bundleURL, version: AppVersion.current)
            UpdateChecker.shared.confirmBundleStartup()
        } catch {
            UpdateChecker.shared.reportBundleStartupFailure(error.localizedDescription)
        }
    }
}
