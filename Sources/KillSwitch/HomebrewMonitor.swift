import AppKit
import Combine
import Foundation
import SoftwareInventoryCore
import os

/// Shared Homebrew state for the Homebrew, Applications, and Security pages. Every action
/// runs the located `brew` executable on a serial background queue; KillSwitch never
/// installs Homebrew or edits its files directly.
@MainActor
final class HomebrewMonitor: ObservableObject {
    static let shared = HomebrewMonitor()

    enum Availability: Equatable {
        case unknown
        case notInstalled
        case installed(HomebrewInstallation)
    }

    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var packages: [HomebrewPackage] = []
    /// True only while the latest inventory listing succeeded; empty and all-clear states
    /// must not be shown without it.
    @Published private(set) var inventoryLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var activeOperation: String?
    @Published private(set) var transcript: HomebrewTranscript?
    @Published private(set) var errorMessage: String?
    /// Full names of running casks; nil when running apps could not be listed.
    @Published private(set) var runningCasks: Set<String>? = []

    var isBusy: Bool { isLoading || activeOperation != nil }
    var outdated: [HomebrewPackage] { packages.filter(\.isOutdated) }
    var upgradable: [HomebrewPackage] {
        packages.filter { $0.canUpgrade && HomebrewCommandPlanner.runningRestriction($0, running: runningCasks) == nil }
    }

    func restriction(for package: HomebrewPackage) -> String? {
        package.upgradeRestriction ?? HomebrewCommandPlanner.runningRestriction(package, running: runningCasks)
    }
    var installation: HomebrewInstallation? {
        if case .installed(let installation) = availability { return installation }
        return nil
    }

    private let queue = DispatchQueue(label: "killswitch.homebrew", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "homebrew")

    private init() {}

    func loadIfNeeded() {
        guard !inventoryLoaded, availability != .notInstalled else { return }
        reload()
    }

    func reload() {
        guard !isBusy else { return }
        guard let installation = HomebrewInstallation.locate() else {
            availability = .notInstalled
            packages = []
            inventoryLoaded = false
            return
        }
        availability = .installed(installation)
        isLoading = true
        let service = HomebrewService(installation: installation)
        let bundles = Self.runningBundleIDs()
        queue.async { [weak self] in
            let result = Result { try service.loadPackages() }
            let running = (try? result.get()).flatMap {
                RunningCaskDetector.runningCasks($0, installation: installation,
                                                 processPaths: RunningCaskDetector.processPaths(runner: NativeSoftwareCommandRunner()),
                                                 runningBundleIDs: bundles)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let packages):
                    self.packages = packages
                    self.runningCasks = running
                    self.inventoryLoaded = true
                    self.errorMessage = nil
                case .failure(let error):
                    self.inventoryLoaded = false
                    self.report("Homebrew packages could not be listed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Fetches newer formula and cask definitions with `brew update`, then relists packages.
    func updateMetadata() {
        guard let installation else { return }
        run("Updating Homebrew", commands: [installation.updateCommand])
    }

    func upgradeAll() {
        guard let installation else { return }
        do {
            let commands = try HomebrewCommandPlanner.upgradeAll(packages, installation: installation, running: runningCasks)
            run("Upgrading \(upgradable.count) package(s)", commands: commands, recheckRunning: true)
        } catch {
            report(error.localizedDescription)
        }
    }

    func upgrade(_ package: HomebrewPackage) {
        guard let installation else { return }
        do {
            let command = try HomebrewCommandPlanner.upgrade(package, installation: installation, running: runningCasks)
            run("Upgrading \(package.displayName)", commands: [command], recheckRunning: true)
        } catch {
            report(error.localizedDescription)
        }
    }

    func uninstall(_ package: HomebrewPackage) {
        guard let installation else { return }
        do {
            run("Uninstalling \(package.displayName)", commands: [try HomebrewCommandPlanner.uninstall(package, installation: installation)])
        } catch {
            report(error.localizedDescription)
        }
    }

    func dismissTranscript() {
        transcript = nil
    }

    func clearError() {
        errorMessage = nil
    }

    /// GUI apps by bundle identifier, read on the main thread where AppKit keeps the list current.
    nonisolated private static func runningBundleIDs() -> Set<String> {
        let read = { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    private func run(_ label: String, commands: [SoftwareCommand], recheckRunning: Bool = false) {
        guard !isBusy, let installation else { return }
        activeOperation = label
        errorMessage = nil
        transcript = nil
        let service = HomebrewService(installation: installation)
        let packages = packages
        logger.notice("\(label, privacy: .public): \(commands.map(\.displayString).joined(separator: "; "), privacy: .public)")
        queue.async { [weak self] in
            // Each cask upgrade rechecks whether its app started running since the plan.
            let transcript = service.perform(commands) { command in
                guard recheckRunning, command.arguments.contains("--cask"), let name = command.arguments.last,
                      let package = packages.first(where: { $0.kind == .cask && $0.fullName == name }) else { return nil }
                let bundles = Self.runningBundleIDs()
                let running = RunningCaskDetector.runningCasks(
                    [package], installation: installation,
                    processPaths: RunningCaskDetector.processPaths(runner: NativeSoftwareCommandRunner()), runningBundleIDs: bundles
                )
                return HomebrewCommandPlanner.runningRestriction(package, running: running)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.activeOperation = nil
                self.transcript = transcript
                if let failure = transcript.failure {
                    self.report("\(label) failed: \(failure)")
                }
                // Even a failed command may have changed some packages.
                self.reload()
            }
        }
    }

    private func report(_ message: String) {
        errorMessage = message
        // brew errors can include home-folder paths, so keep the default private redaction.
        logger.error("\(message)")
    }
}

#if KILLSWITCH_PERFORMANCE_PROBE
extension HomebrewMonitor {
    /// Publishes fictional packages in memory only; brew is never run.
    func publishPerformanceFixture() {
        availability = .installed(HomebrewInstallation(executable: "/synthetic/homebrew/bin/brew"))
        packages = [
            HomebrewPackage(kind: .formula, name: "synthetic-tool", fullName: "synthetic-tool", displayName: "synthetic-tool",
                            summary: "Synthetic command-line tool", installedVersion: "1.0", latestVersion: "1.1", isOutdated: true),
            HomebrewPackage(kind: .formula, name: "pinned-lib", fullName: "pinned-lib", displayName: "pinned-lib",
                            summary: "Pinned synthetic library", installedVersion: "2.0", latestVersion: "2.1",
                            isOutdated: true, isPinned: true, installedOnRequest: false),
            HomebrewPackage(kind: .formula, name: "current-lib", fullName: "current-lib", displayName: "current-lib",
                            summary: "Current synthetic library", installedVersion: "3.0", latestVersion: "3.0", isOutdated: false),
            HomebrewPackage(kind: .cask, name: "synthetic-editor", fullName: "synthetic-editor", displayName: "Synthetic Editor",
                            summary: "Synthetic editor app", installedVersion: "4.0", latestVersion: "4.2", isOutdated: true,
                            appPaths: ["/Applications/Synthetic Editor.app"]),
            HomebrewPackage(kind: .cask, name: "synthetic-browser", fullName: "synthetic-browser", displayName: "Synthetic Browser",
                            summary: "Self-updating synthetic browser", installedVersion: "5.0", latestVersion: "5.0",
                            isOutdated: false, autoUpdates: true, appPaths: ["/Applications/Synthetic Browser.app"]),
            HomebrewPackage(kind: .cask, name: "synthetic-chat", fullName: "synthetic-chat", displayName: "Synthetic Chat",
                            summary: "Running synthetic chat app", installedVersion: "6.0", latestVersion: "6.1", isOutdated: true,
                            appPaths: ["/Applications/Synthetic Chat.app"])
        ]
        runningCasks = ["synthetic-chat"]
        inventoryLoaded = true
    }
}
#endif
