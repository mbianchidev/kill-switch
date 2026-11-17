import AppKit
import Combine
import Foundation
import SoftwareInventoryCore
import os

/// Reads macOS protections and available macOS updates on demand. Nothing is changed or installed.
@MainActor
final class SecurityMonitor: ObservableObject {
    static let shared = SecurityMonitor()

    @Published private(set) var checks: [SecurityCheck] = []
    @Published private(set) var isCheckingPosture = false
    @Published private(set) var postureCheckedAt: Date?
    @Published private(set) var updates: SoftwareUpdateList?
    @Published private(set) var updatesError: String?
    @Published private(set) var isListingUpdates = false
    @Published private(set) var isFullScan = false
    @Published private(set) var updatesListedAt: Date?
    @Published private(set) var lastSystemUpdateCheck: Date?
    @Published private(set) var errorMessage: String?

    private let queue = DispatchQueue(label: "killswitch.security", qos: .userInitiated, attributes: .concurrent)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "security")

    private init() {}

    func loadIfNeeded() {
        if postureCheckedAt == nil { refreshPosture() }
        if updatesListedAt == nil { listUpdates(scan: false) }
    }

    func refreshPosture() {
        guard !isCheckingPosture else { return }
        isCheckingPosture = true
        let service = SecurityPostureService()
        queue.async { [weak self] in
            let checks = service.checks()
            let lastCheck = service.lastSuccessfulUpdateCheck()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checks = checks
                self.lastSystemUpdateCheck = lastCheck
                self.postureCheckedAt = Date()
                self.isCheckingPosture = false
            }
        }
    }

    /// Without `scan`, reuses the most recent macOS scan; a scan contacts Apple and can take minutes.
    func listUpdates(scan: Bool) {
        guard !isListingUpdates else { return }
        isListingUpdates = true
        isFullScan = scan
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let service = SoftwareUpdateService()
        queue.async { [weak self] in
            let result = Result { try service.list(scan: scan, currentMajorVersion: major) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isListingUpdates = false
                self.isFullScan = false
                self.updatesListedAt = Date()
                switch result {
                case .success(let list):
                    self.updates = list
                    self.updatesError = nil
                case .failure(let error):
                    self.updatesError = "macOS updates could not be listed: \(error.localizedDescription)"
                    self.logger.error("\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func openSoftwareUpdate() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.softwareupdate"
        ]
        guard candidates.compactMap(URL.init(string:)).contains(where: { NSWorkspace.shared.open($0) }) else {
            errorMessage = "Could not open Software Update settings."
            return
        }
        errorMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }
}

#if KILLSWITCH_PERFORMANCE_PROBE
extension SecurityMonitor {
    /// Publishes fictional protection states and updates in memory only.
    func publishPerformanceFixture() {
        checks = [
            SecurityCheck(id: .fileVault, title: "FileVault disk encryption", state: .enabled, detail: "FileVault is On."),
            SecurityCheck(id: .firewall, title: "Firewall", state: .disabled, detail: "Firewall is disabled. (State = 0)"),
            SecurityCheck(id: .stealthMode, title: "Firewall stealth mode", state: .disabled,
                          detail: "Firewall stealth mode is off", recommendedOn: false),
            SecurityCheck(id: .gatekeeper, title: "Gatekeeper", state: .enabled, detail: "assessments enabled"),
            SecurityCheck(id: .systemIntegrity, title: "System Integrity Protection", state: .enabled,
                          detail: "System Integrity Protection status: enabled."),
            SecurityCheck(id: .xprotect, title: "XProtect malware definitions", state: .enabled, detail: "Version 9999"),
            SecurityCheck(id: .securityResponses, title: "Automatic security responses", state: .unknown,
                          detail: "Not set explicitly; the macOS default applies.")
        ]
        updates = SoftwareUpdateList(items: [
            SoftwareUpdateItem(label: "macOS Synthetic 26.9.1-25Z001", title: "macOS Synthetic 26.9.1", version: "26.9.1",
                               sizeKiB: 3_181_896, recommended: true, requiresRestart: true, category: .macOSUpdate),
            SoftwareUpdateItem(label: "Safari99.1Synthetic-99.1", title: "Safari", version: "99.1", sizeKiB: 250_130,
                               recommended: true, requiresRestart: false, category: .safari),
            SoftwareUpdateItem(label: "macOS 27.0-26A001", title: "macOS 27.0", version: "27.0", sizeKiB: 11_188_054,
                               recommended: true, requiresRestart: true, category: .macOSUpgrade)
        ], warnings: [])
        let now = Date()
        postureCheckedAt = now
        updatesListedAt = now
        lastSystemUpdateCheck = now.addingTimeInterval(-3_600)
    }
}
#endif
