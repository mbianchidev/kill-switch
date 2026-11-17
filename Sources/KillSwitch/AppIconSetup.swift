import AppKit
import InstallCore
import os

/// Keeps the Dock, Finder, and Launchpad on the bundled icon after an in-place update.
@MainActor
enum AppIconSetup {
    nonisolated private static let logger = Logger(subsystem: "com.killswitch.app", category: "app-icon")

    static func apply(bundleURL: URL = Bundle.main.bundleURL) {
        guard AppDistribution(bundleURL: bundleURL) == .appBundle else { return }
        let refresher = AppIconRefresh(bundleURL: bundleURL)
        // The running Dock tile uses this image directly, so a stale cached icon cannot show.
        if let icon = NSImage(contentsOf: refresher.iconURL) {
            NSApp.applicationIconImage = icon
        } else {
            logger.error("The bundled app icon could not be read.")
        }
        let fingerprint = refresher.fingerprint(version: AppVersion.current)
        guard AppIconRefresh.needsRefresh(fingerprint: fingerprint, refreshed: UserDefaults.standard.string(forKey: AppIconRefresh.defaultsKey)) else {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                if let warning = try AppIconRefresh(bundleURL: bundleURL).refresh() {
                    // Not recorded, so the installed copy of this release still refreshes, for
                    // example after a first launch from the read-only disk image.
                    logger.notice("App icon registered again without marking the bundle changed: \(warning.localizedDescription)")
                } else {
                    UserDefaults.standard.set(fingerprint, forKey: AppIconRefresh.defaultsKey)
                }
            } catch {
                // Retried at the next launch; a read-only location such as a mounted disk image fails here.
                logger.error("App icon refresh failed: \(error.localizedDescription)")
            }
        }
    }
}
