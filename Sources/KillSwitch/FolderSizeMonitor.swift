import AppKit
import Combine
import DiskCleanupCore
import Foundation
import os

struct FolderSizeWatchStatus: Equatable {
    var measurement: FolderSizeMeasurement?
    var isMeasuring = false
    var errorMessage: String?
}

/// Measures watched folders one at a time on a background queue, persists alert
/// state, and raises in-app and macOS alerts when a folder reaches its threshold.
/// Monitoring runs for the app's lifetime, including while the window is hidden.
@MainActor
final class FolderSizeMonitor: ObservableObject {
    static let shared = FolderSizeMonitor()
    // Full folder walks are too heavy for a 30-second cadence.
    static let intervalOptions = SamplingIntervals.standard.filter { $0.seconds >= 60 }
    private static let maxAlerts = 50

    @Published private(set) var watches: [FolderSizeWatch] = []
    @Published private(set) var statuses: [UUID: FolderSizeWatchStatus] = [:]
    @Published private(set) var alerts: [FolderSizeAlert] = []
    @Published private(set) var unacknowledgedAlerts: [FolderSizeAlert] = []
    @Published private(set) var errorMessage: String?
    @Published var intervalSeconds: Int {
        didSet {
            store.setIntervalSeconds(intervalSeconds)
            if started { reschedule() }
        }
    }

    var isMeasuring: Bool { statuses.values.contains { $0.isMeasuring } }
    var lastMeasured: Date? { statuses.values.compactMap { $0.measurement?.measuredAt }.max() }
    var permissionDeniedCount: Int {
        statuses.values.reduce(0) { $0 + ($1.measurement?.permissionDeniedCount ?? 0) }
    }

    private var list = FolderSizeWatchList() {
        didSet { watches = list.watches }
    }
    private let store: FolderSizeWatchStore
    private let measurer = FolderSizeMeasurer()
    private let workQueue = DispatchQueue(label: "killswitch.folder-size.work", qos: .utility)
    private let notificationQueue = DispatchQueue(label: "killswitch.folder-size.notification", qos: .utility)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "folder-size")
    private var tokens: [UUID: DiskCleanupCancellationToken] = [:]
    private var timer: DispatchSourceTimer?
    private var started = false

    private init(store: FolderSizeWatchStore = FolderSizeWatchStore()) {
        self.store = store
        intervalSeconds = store.intervalSeconds(allowed: Self.intervalOptions.map(\.seconds))
        do {
            list = try store.loadWatches()
        } catch {
            report(error.localizedDescription)
        }
        watches = list.watches
    }

    func start() {
        guard !started else { return }
        started = true
        reschedule()
        checkNow()
    }

    func stop() {
        started = false
        timer?.cancel()
        timer = nil
        for token in tokens.values { token.cancel() }
        tokens.removeAll()
        for id in statuses.keys { statuses[id]?.isMeasuring = false }
    }

    func checkNow() {
        for watch in list.watches { enqueueMeasurement(of: watch) }
    }

    func addFolders(_ urls: [URL]) {
        var failures: [String] = []
        var added: [FolderSizeWatch] = []
        for url in urls {
            do {
                added.append(try list.add(folder: url))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !added.isEmpty {
            errorMessage = nil
            persist()
            for watch in added { enqueueMeasurement(of: watch) }
        }
        if !failures.isEmpty { report(failures.joined(separator: "\n")) }
    }

    func remove(_ id: UUID) {
        cancelMeasurement(of: id)
        guard list.remove(id: id) != nil else { return }
        statuses[id] = nil
        unacknowledgedAlerts.removeAll { $0.watchID == id }
        persist()
    }

    /// Saves a new threshold and measures again so the alert is judged against it.
    func setThreshold(_ bytes: UInt64, for id: UUID) {
        guard list.watch(id: id)?.thresholdBytes != bytes else { return }
        do {
            try list.setThreshold(bytes, for: id)
        } catch {
            report(error.localizedDescription)
            return
        }
        persist()
        if let watch = list.watch(id: id) { enqueueMeasurement(of: watch) }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        do {
            try list.setEnabled(enabled, for: id)
        } catch {
            report(error.localizedDescription)
            return
        }
        persist()
        if enabled, let watch = list.watch(id: id) {
            enqueueMeasurement(of: watch)
        } else {
            cancelMeasurement(of: id)
        }
    }

    func acknowledgeAlerts() {
        guard !unacknowledgedAlerts.isEmpty else { return }
        unacknowledgedAlerts.removeAll()
    }

    func clearError() {
        errorMessage = nil
    }

    func revealInFinder(_ watch: FolderSizeWatch) {
        if !revealPathInFinder(watch.path) {
            report(FolderSizeWatchError.folderUnavailable(watch.path).localizedDescription)
        }
    }

    func openFullDiskAccess() {
        if !openFullDiskAccessPane() {
            report("Could not open Full Disk Access settings.")
        }
    }

    private func enqueueMeasurement(of watch: FolderSizeWatch) {
        guard watch.isEnabled, tokens[watch.id] == nil else { return }
        let token = DiskCleanupCancellationToken()
        let id = watch.id
        let url = watch.url
        let measurer = measurer
        tokens[id] = token
        statuses[id, default: FolderSizeWatchStatus()].isMeasuring = true
        workQueue.async { [weak self] in
            let result = Result { try measurer.measure(url, cancellationToken: token) }
            DispatchQueue.main.async {
                self?.finishMeasurement(of: id, token: token, result: result)
            }
        }
    }

    private func cancelMeasurement(of id: UUID) {
        tokens.removeValue(forKey: id)?.cancel()
        statuses[id]?.isMeasuring = false
    }

    private func finishMeasurement(
        of id: UUID,
        token: DiskCleanupCancellationToken,
        result: Result<FolderSizeMeasurement, Error>
    ) {
        guard tokens[id] === token else { return }
        tokens[id] = nil
        guard list.watch(id: id) != nil else {
            statuses[id] = nil
            return
        }
        var status = statuses[id] ?? FolderSizeWatchStatus()
        status.isMeasuring = false
        switch result {
        case .success(let measurement):
            status.measurement = measurement
            status.errorMessage = nil
            statuses[id] = status
            let previous = list
            let alert = list.record(measurement, for: id)
            if list != previous { persist() }
            if let alert { raise(alert) }
        case .failure(FolderSizeWatchError.cancelled):
            statuses[id] = status
        case .failure(let error):
            status.errorMessage = error.localizedDescription
            statuses[id] = status
            logger.error("Folder size measurement failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func raise(_ alert: FolderSizeAlert) {
        alerts.insert(alert, at: 0)
        if alerts.count > Self.maxAlerts { alerts.removeLast(alerts.count - Self.maxAlerts) }
        unacknowledgedAlerts.insert(alert, at: 0)
        if unacknowledgedAlerts.count > Self.maxAlerts {
            unacknowledgedAlerts.removeLast(unacknowledgedAlerts.count - Self.maxAlerts)
        }
        logger.notice("Folder size alert: \(alert.path) reached \(alert.sizeBytes) of \(alert.thresholdBytes) bytes")

        let name = alert.name
        let body = Self.notificationBody(for: alert)
        notificationQueue.async { [weak self] in
            let delivered = ProcessSampler.notify(title: "Folder size alert", subtitle: name, body: body)
            DispatchQueue.main.async {
                guard !delivered else { return }
                self?.report("macOS did not deliver the notification for \(name). The alert remains listed in KillSwitch.")
            }
        }
    }

    private static func notificationBody(for alert: FolderSizeAlert) -> String {
        let path = (alert.path as NSString).abbreviatingWithTildeInPath
        let size = alert.isMeasurementComplete ? formatBytes(alert.sizeBytes) : "at least \(formatBytes(alert.sizeBytes))"
        return "\(path) uses \(size), reaching its \(formatBytes(alert.thresholdBytes)) alert limit."
    }

    private func persist() {
        do {
            try store.save(list)
        } catch {
            report(error.localizedDescription)
        }
    }

    private func report(_ message: String) {
        errorMessage = message
        logger.error("\(message, privacy: .public)")
    }

    private func reschedule() {
        timer?.cancel()
        let interval = max(60, intervalSeconds)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .seconds(interval),
            repeating: .seconds(interval),
            leeway: .seconds(max(1, min(30, interval / 10)))
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.checkNow() }
        }
        timer.resume()
        self.timer = timer
    }
}

#if KILLSWITCH_PERFORMANCE_PROBE
extension FolderSizeMonitor {
    /// Publishes fictional folders in memory only; nothing is measured or persisted.
    func publishPerformanceFixture() {
        let now = Date()
        let gigabyte = FolderSizeUnit.gigabytes.bytes
        let downloads = FolderSizeWatch(
            path: "/synthetic/Downloads", thresholdBytes: 10 * gigabyte, alertState: .reached(since: now)
        )
        let cache = FolderSizeWatch(path: "/synthetic/Projects/build-cache", thresholdBytes: 50 * gigabyte)
        let archive = FolderSizeWatch(
            path: "/synthetic/Archive", thresholdBytes: 2 * FolderSizeUnit.terabytes.bytes, isEnabled: false
        )
        let restricted = FolderSizeWatch(path: "/synthetic/Shared", thresholdBytes: 512 * FolderSizeUnit.megabytes.bytes)
        func measured(_ watch: FolderSizeWatch, _ bytes: UInt64, denied: Int = 0) -> FolderSizeWatchStatus {
            FolderSizeWatchStatus(measurement: FolderSizeMeasurement(
                path: watch.path, sizeBytes: bytes, fileCount: 1_000, permissionDeniedCount: denied,
                unreadableItemCount: 0, measuredAt: now
            ))
        }
        list = FolderSizeWatchList([downloads, cache, archive, restricted])
        statuses = [
            downloads.id: measured(downloads, 12 * gigabyte + gigabyte / 2),
            cache.id: measured(cache, 46 * gigabyte),
            restricted.id: measured(restricted, 300 * FolderSizeUnit.megabytes.bytes, denied: 3)
        ]
        let alert = FolderSizeAlert(
            watchID: downloads.id, path: downloads.path, sizeBytes: 12 * gigabyte + gigabyte / 2,
            thresholdBytes: downloads.thresholdBytes, date: now, isMeasurementComplete: true
        )
        alerts = [alert]
        unacknowledgedAlerts = [alert]
    }
}
#endif
