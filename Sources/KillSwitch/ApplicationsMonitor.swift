import Foundation
import SoftwareInventoryCore
import os

/// Lists installed applications and assesses each with Gatekeeper in small parallel batches.
/// Assessments are cached per path and modification date for the app's lifetime.
@MainActor
final class ApplicationsMonitor: ObservableObject {
    static let shared = ApplicationsMonitor()
    private static let batchSize = 8

    @Published private(set) var applications: [InstalledApplication] = []
    @Published private(set) var trust: [String: ApplicationTrust] = [:]
    @Published private(set) var failures: [String] = []
    @Published private(set) var isScanning = false
    @Published private(set) var pendingAssessments = 0
    @Published private(set) var lastScan: Date?

    private struct CacheKey: Hashable {
        let path: String
        let modified: Date?
    }

    private var cache: [CacheKey: ApplicationTrust] = [:]
    private var generation = 0
    private let queue = DispatchQueue(label: "killswitch.applications", qos: .utility)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "applications")

    private init() {}

    func loadIfNeeded() {
        guard lastScan == nil, !isScanning else { return }
        rescan()
    }

    func rescan() {
        guard !isScanning else { return }
        generation += 1
        let generation = generation
        isScanning = true
        queue.async { [weak self] in
            let result = ApplicationScanner().scan()
            DispatchQueue.main.async {
                self?.finishScan(result, generation: generation)
            }
        }
    }

    private func finishScan(_ result: ApplicationScanResult, generation: Int) {
        guard generation == self.generation else { return }
        isScanning = false
        lastScan = Date()
        applications = result.applications
        failures = result.failures
        for failure in result.failures { logger.error("Application scan: \(failure, privacy: .public)") }

        var known: [String: ApplicationTrust] = [:]
        var unknown: [InstalledApplication] = []
        for app in result.applications {
            if let cached = cache[CacheKey(path: app.path, modified: app.modificationDate)] {
                known[app.path] = cached
            } else {
                unknown.append(app)
            }
        }
        trust = known
        pendingAssessments = unknown.count
        assess(unknown, generation: generation)
    }

    private func assess(_ remaining: [InstalledApplication], generation: Int) {
        guard !remaining.isEmpty else { return }
        let batch = Array(remaining.prefix(Self.batchSize))
        let rest = Array(remaining.dropFirst(Self.batchSize))
        let service = ApplicationTrustService()
        queue.async { [weak self] in
            var results = [ApplicationTrust?](repeating: nil, count: batch.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: batch.count) { index in
                let value = service.assess(batch[index])
                lock.lock()
                results[index] = value
                lock.unlock()
            }
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                for (app, value) in zip(batch, results) {
                    guard let value else { continue }
                    self.trust[app.path] = value
                    self.cache[CacheKey(path: app.path, modified: app.modificationDate)] = value
                }
                self.pendingAssessments = rest.count
                self.assess(rest, generation: generation)
            }
        }
    }
}

#if KILLSWITCH_PERFORMANCE_PROBE
extension ApplicationsMonitor {
    /// Publishes fictional applications in memory only; nothing is scanned or assessed.
    func publishPerformanceFixture() {
        let apps: [(String, String, ApplicationTrust)] = [
            ("Synthetic Editor", "/Applications/Synthetic Editor.app", .notarized),
            ("Synthetic Browser", "/Applications/Synthetic Browser.app", .notarized),
            ("Synthetic Store App", "/Applications/Synthetic Store App.app", .appStore),
            ("Synthetic Local Build", "/Applications/Synthetic Local Build.app", .local("Gatekeeper rejected it; it is unsigned, ad-hoc signed, or not notarized.")),
            ("Synthetic Utility", "/Applications/Utilities/Synthetic Utility.app", .apple)
        ]
        applications = apps.map {
            InstalledApplication(path: $0.1, name: $0.0, bundleIdentifier: "com.example.\($0.0.lowercased().replacingOccurrences(of: " ", with: "-"))",
                                 version: "1.0", modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        }
        trust = Dictionary(uniqueKeysWithValues: apps.map { ($0.1, $0.2) })
        lastScan = Date()
    }
}
#endif
