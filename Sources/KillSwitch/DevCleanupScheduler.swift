import Foundation
import DevCleanupCore
import os

/// Runs Dev cleanup at the saved interval for as long as KillSwitch runs, on any page and with
/// the window hidden, whenever saved auto-kill is enabled. No Dev cleanup page visit is needed.
/// Saved settings are reread before every pass and every termination, so disabling auto-kill or
/// quitting stops further kills, including during a pass.
final class DevCleanupScheduler: ObservableObject {
    static let shared = DevCleanupScheduler()

    @Published private(set) var lastRun: Date?
    @Published private(set) var lastKilled: [CleanedProcess] = []
    @Published private(set) var lastError: String?

    /// The longest wait between checks, so interval and auto-kill changes apply within a minute.
    static let maximumCheckDelay = Duration.seconds(60)

    private let providedPreferences: DevCleanupPreferences?
    private let providedService: DevCleanupService?
    // Created on first use on `queue`, so observing the status never touches live preferences.
    private lazy var preferences = providedPreferences ?? DevCleanupPreferences()
    private lazy var service = providedService ?? DevCleanupService.live()
    private let notify: ([CleanedProcess], Int) -> Void
    private let queue = DispatchQueue(label: "killswitch.dev-cleanup.background", qos: .utility)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "dev-cleanup")
    private let session = OSAllocatedUnfairLock<UUID?>(initialState: nil)
    private var timer: DispatchSourceTimer?
    /// Touched only on `queue`. A pass is due once the saved interval has elapsed since this.
    private var intervalStart = ContinuousClock.now

    init(
        preferences: DevCleanupPreferences? = nil,
        service: DevCleanupService? = nil,
        notify: @escaping ([CleanedProcess], Int) -> Void = DevCleanupScheduler.notifyTerminated(_:ageThresholdHours:)
    ) {
        providedPreferences = preferences
        providedService = service
        self.notify = notify
    }

    /// Starts background passes; the first runs one saved interval after launch.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
#if KILLSWITCH_PERFORMANCE_PROBE
        precondition(providedService != nil, "Synthetic background cleanup requires an explicitly injected mock service.")
#endif
        guard timer == nil else { return }
        let current = UUID()
        session.withLock { $0 = current }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // One-shot checks sleep until the next pass is due, so timer jitter never adds a whole check period.
        timer.setEventHandler { [weak self, weak timer] in
            guard let self, let timer else { return }
            let delay = self.evaluate(session: current, force: false)
            if self.isCurrent(current) { Self.schedule(timer, after: delay) }
        }
        queue.async { [weak self] in
            if let self {
                self.intervalStart = .now
                Self.schedule(timer, after: self.nextCheckDelay(settings: self.preferences.load()))
            }
            timer.resume()
        }
        self.timer = timer
    }

    /// Revokes the session immediately, so a running pass terminates nothing further.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        session.withLock { $0 = nil }
        timer?.cancel()
        timer = nil
    }

    private func isCurrent(_ current: UUID) -> Bool { session.withLock { $0 == current } }

    private static func schedule(_ timer: DispatchSourceTimer, after delay: Duration) {
        let milliseconds = Int(delay.components.seconds * 1_000 + delay.components.attoseconds / 1_000_000_000_000_000)
        timer.schedule(deadline: .now() + .milliseconds(max(1_000, milliseconds)), repeating: .never, leeway: .seconds(1))
    }

    private static func interval(_ settings: DevCleanupSettings) -> Duration {
        .seconds(max(5, settings.cleanupIntervalSeconds))
    }

    /// Time until the next pass is due, capped so saved changes are noticed within a minute.
    private func nextCheckDelay(settings: DevCleanupSettings) -> Duration {
        guard settings.autoKillEnabled else { return Self.maximumCheckDelay }
        let remaining = Self.interval(settings) - (ContinuousClock.now - intervalStart)
        return min(max(remaining, .seconds(1)), Self.maximumCheckDelay)
    }

    /// Runs a due pass and returns the delay until the next check.
    @discardableResult
    private func evaluate(session current: UUID, force: Bool) -> Duration {
        guard isCurrent(current) else { return Self.maximumCheckDelay }
        let settings = preferences.load()
        guard settings.autoKillEnabled else {
            // Re-enabling waits a full interval instead of running an overdue pass at once.
            intervalStart = .now
            return Self.maximumCheckDelay
        }
        // Dispatch never fires early; the tolerance only absorbs clock rounding.
        guard force || ContinuousClock.now - intervalStart >= Self.interval(settings) - .milliseconds(500) else {
            return nextCheckDelay(settings: settings)
        }
        intervalStart = .now
        do {
            let result = try service.cleanup(configuration: settings.configuration, shouldTerminate: { [self] in
                isCurrent(current) && preferences.load().autoKillEnabled
            })
            if !result.killed.isEmpty {
                let summary = result.killed.map { "\($0.runtime) PID \($0.pid)" }.joined(separator: ", ")
                logger.notice("Background Dev cleanup terminated \(result.killed.count) process(es): \(summary, privacy: .public)")
                fputs("KillSwitch background dev-cleanup terminated: \(summary)\n", stderr)
                notify(result.killed, settings.ageThresholdHours)
            }
            DispatchQueue.main.async {
                self.lastRun = Date()
                self.lastKilled = result.killed
                self.lastError = nil
            }
        } catch {
            logger.error("Background Dev cleanup failed: \(error.localizedDescription, privacy: .public)")
            fputs("KillSwitch background dev-cleanup failed: \(error.localizedDescription)\n", stderr)
            DispatchQueue.main.async { self.lastError = error.localizedDescription }
        }
        return nextCheckDelay(settings: settings)
    }

    static func notifyTerminated(_ killed: [CleanedProcess], ageThresholdHours: Int) {
        let listed = killed.prefix(3).map { "\($0.runtime) (PID \($0.pid))" }.joined(separator: ", ")
        let more = killed.count > 3 ? ", and \(killed.count - 3) more" : ""
        let body = "Stopped \(killed.count) dev server(s) running longer than \(ageThresholdHours)h: \(listed)\(more)."
        if !ProcessSampler.notify(title: "KillSwitch", subtitle: "Dev cleanup", body: body) {
            fputs("KillSwitch could not post the background dev-cleanup notification: \(body)\n", stderr)
        }
    }
}

#if KILLSWITCH_PERFORMANCE_PROBE
extension DevCleanupScheduler {
    /// Runs one pass now on the work queue, ignoring the interval, as background cleanup would.
    func performanceRunPass() {
        queue.sync {
            guard let current = session.withLock({ $0 }) else { return }
            evaluate(session: current, force: true)
        }
    }

    func performanceEnqueue(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
    func performanceDrain() { queue.sync {} }
    var performanceIsScheduled: Bool { timer != nil }
}
#endif
