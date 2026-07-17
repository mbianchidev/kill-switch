import AppKit
import Combine
import CoreGraphics
import Foundation
import ScreenTimeCore
import os

@MainActor
final class ScreenTimeMonitor: ObservableObject {
    static let shared = ScreenTimeMonitor()
    static let reminderHourRange = 1...12
    static let defaultReminderHours = 2

    @Published private(set) var activeSecondsToday: TimeInterval = 0
    @Published private(set) var currentStretchSeconds: TimeInterval = 0
    @Published private(set) var idleSeconds: TimeInterval = 0
    @Published private(set) var isActive = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastReminderDate: Date?
    @Published private(set) var errorMessage: String?

    @Published var remindersEnabled: Bool {
        didSet {
            ScreenTimeDefaults.set(remindersEnabled, .remindersEnabled)
            errorMessage = nil
        }
    }

    @Published var reminderIntervalHours: Int {
        didSet {
            let clamped = min(max(reminderIntervalHours, Self.reminderHourRange.lowerBound), Self.reminderHourRange.upperBound)
            if reminderIntervalHours != clamped {
                reminderIntervalHours = clamped
                return
            }
            ScreenTimeDefaults.set(reminderIntervalHours, .reminderIntervalHours)
            errorMessage = nil
        }
    }

    var reminderProgress: Double {
        guard remindersEnabled else { return 0 }
        let interval = reminderIntervalSeconds
        guard interval > 0 else { return 0 }
        return currentStretchSeconds.truncatingRemainder(dividingBy: interval) / interval
    }

    var secondsUntilReminder: TimeInterval? {
        guard remindersEnabled else { return nil }
        let interval = reminderIntervalSeconds
        let remainder = currentStretchSeconds.truncatingRemainder(dividingBy: interval)
        return interval - remainder
    }

    private enum SuspensionReason: Hashable {
        case screenSleep
        case sessionInactive
        case systemSleep
    }

    private let calendar = Calendar.autoupdatingCurrent
    private let logger = Logger(subsystem: "com.killswitch.app", category: "screen-time")
    private let timerQueue = DispatchQueue(label: "killswitch.screen-time.timer", qos: .utility)
    private let notificationQueue = DispatchQueue(label: "killswitch.screen-time.notification", qos: .utility)
    private var tracker: ScreenTimeTracker
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var suspensionReasons: Set<SuspensionReason> = []

    private init() {
        let now = Date()
        let storedHours = ScreenTimeDefaults.int(
            .reminderIntervalHours,
            default: Self.defaultReminderHours
        )
        remindersEnabled = ScreenTimeDefaults.bool(.remindersEnabled, default: false)
        reminderIntervalHours = min(
            max(storedHours, Self.reminderHourRange.lowerBound),
            Self.reminderHourRange.upperBound
        )
        lastReminderDate = ScreenTimeDefaults.date(.lastReminderDate)
        tracker = ScreenTimeTracker(
            snapshot: ScreenTimeDefaults.snapshot(now: now, calendar: calendar),
            now: now,
            calendar: calendar
        )
        publishSnapshot(isActive: false, idleSeconds: 0, updatedAt: nil)
    }

    func start() {
        guard timer == nil else { return }
        installWorkspaceObservers()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .automaticTerminationDisabled],
            reason: "Monitoring active screen time"
        )
        sampleNow()

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            let sampleDate = Date()
            let idleSeconds = Self.systemIdleSeconds()
            DispatchQueue.main.async {
                guard let self, self.timer != nil else { return }
                self.recordSample(at: sampleDate, idleSeconds: idleSeconds, allowReminder: true)
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        guard timer != nil else {
            persistSnapshot()
            return
        }

        if suspensionReasons.isEmpty {
            recordSample(
                at: Date(),
                idleSeconds: Self.systemIdleSeconds(),
                allowReminder: false
            )
        }
        timer?.cancel()
        timer = nil
        removeWorkspaceObservers()

        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        persistSnapshot()
    }

    func resetCurrentStretch() {
        let now = Date()
        let currentIdleSeconds = Self.systemIdleSeconds()
        if suspensionReasons.isEmpty {
            _ = tracker.sample(
                at: now,
                idleSeconds: currentIdleSeconds,
                reminderInterval: nil,
                calendar: calendar
            )
        }
        _ = tracker.endStretch(at: now, calendar: calendar)
        publishSnapshot(
            isActive: currentIdleSeconds < ScreenTimeTracker.activeIdleThreshold,
            idleSeconds: currentIdleSeconds,
            updatedAt: now
        )
        persistSnapshot()
    }

    private var reminderIntervalSeconds: TimeInterval {
        TimeInterval(reminderIntervalHours * 3_600)
    }

    private func sampleNow() {
        recordSample(
            at: Date(),
            idleSeconds: Self.systemIdleSeconds(),
            allowReminder: true
        )
    }

    private func recordSample(
        at date: Date,
        idleSeconds: TimeInterval,
        allowReminder: Bool
    ) {
        guard suspensionReasons.isEmpty else {
            publishSnapshot(isActive: false, idleSeconds: idleSeconds, updatedAt: date)
            return
        }

        let update = tracker.sample(
            at: date,
            idleSeconds: idleSeconds,
            reminderInterval: allowReminder && remindersEnabled ? reminderIntervalSeconds : nil,
            calendar: calendar
        )
        publishSnapshot(isActive: update.isActive, idleSeconds: idleSeconds, updatedAt: date)
        persistSnapshot()

        if update.shouldRemind {
            postBreakReminder(stretchSeconds: tracker.snapshot.currentStretchSeconds)
        }
    }

    private func postBreakReminder(stretchSeconds: TimeInterval) {
        let intervalHours = reminderIntervalHours
        let activeHours = max(intervalHours, Int(stretchSeconds / 3_600))
        notificationQueue.async { [weak self] in
            let delivered = ProcessSampler.notify(
                title: "Touch grass",
                subtitle: "Screen time break",
                body: "You've been active for \(activeHours) \(activeHours == 1 ? "hour" : "hours"). Stand up, stretch, and get away from the screen."
            )
            DispatchQueue.main.async {
                guard let self else { return }
                if delivered {
                    let now = Date()
                    self.lastReminderDate = now
                    self.errorMessage = nil
                    ScreenTimeDefaults.set(now, .lastReminderDate)
                } else {
                    let message = "The break reminder could not be delivered by macOS."
                    self.errorMessage = message
                    self.logger.error("\(message, privacy: .public)")
                }
            }
        }
    }

    private func publishSnapshot(
        isActive: Bool,
        idleSeconds: TimeInterval,
        updatedAt: Date?
    ) {
        activeSecondsToday = tracker.snapshot.activeSecondsToday
        currentStretchSeconds = tracker.snapshot.currentStretchSeconds
        self.idleSeconds = max(0, idleSeconds)
        self.isActive = suspensionReasons.isEmpty && isActive
        lastUpdated = updatedAt
    }

    private func installWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspend(.systemSleep)
                }
            }
        )
        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resume(.systemSleep)
                }
            }
        )
        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspend(.screenSleep)
                }
            }
        )
        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resume(.screenSleep)
                }
            }
        )
        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspend(.sessionInactive)
                }
            }
        )
        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resume(.sessionInactive)
                }
            }
        )
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    private func suspend(_ reason: SuspensionReason) {
        suspensionReasons.insert(reason)
        let now = Date()
        _ = tracker.endStretch(at: now, calendar: calendar)
        publishSnapshot(isActive: false, idleSeconds: idleSeconds, updatedAt: now)
        persistSnapshot()
    }

    private func resume(_ reason: SuspensionReason) {
        suspensionReasons.remove(reason)
        let now = Date()
        _ = tracker.endStretch(at: now, calendar: calendar)
        publishSnapshot(isActive: false, idleSeconds: 0, updatedAt: now)
        persistSnapshot()
    }

    private func persistSnapshot() {
        ScreenTimeDefaults.set(tracker.snapshot)
    }

    nonisolated private static func systemIdleSeconds() -> TimeInterval {
        guard let anyInputEvent = CGEventType(rawValue: UInt32.max) else {
            Logger(subsystem: "com.killswitch.app", category: "screen-time")
                .fault("CoreGraphics did not accept the any-input event type.")
            return ScreenTimeTracker.breakIdleThreshold
        }
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEvent
        )
    }
}

private enum ScreenTimeDefaults {
    enum Key: String {
        case activeSecondsToday = "screentime.activeSecondsToday"
        case currentStretchSeconds = "screentime.currentStretchSeconds"
        case dayStart = "screentime.dayStart"
        case lastReminderDate = "screentime.lastReminderDate"
        case lastSampleDate = "screentime.lastSampleDate"
        case reminderIntervalHours = "screentime.reminderIntervalHours"
        case remindersEnabled = "screentime.remindersEnabled"
    }

    static func snapshot(now: Date, calendar: Calendar) -> ScreenTimeSnapshot {
        ScreenTimeSnapshot(
            dayStart: date(.dayStart) ?? calendar.startOfDay(for: now),
            activeSecondsToday: UserDefaults.standard.double(forKey: Key.activeSecondsToday.rawValue),
            currentStretchSeconds: UserDefaults.standard.double(forKey: Key.currentStretchSeconds.rawValue),
            lastSampleDate: date(.lastSampleDate)
        )
    }

    static func set(_ snapshot: ScreenTimeSnapshot) {
        set(snapshot.dayStart, .dayStart)
        set(snapshot.activeSecondsToday, .activeSecondsToday)
        set(snapshot.currentStretchSeconds, .currentStretchSeconds)
        if let lastSampleDate = snapshot.lastSampleDate {
            set(lastSampleDate, .lastSampleDate)
        } else {
            UserDefaults.standard.removeObject(forKey: Key.lastSampleDate.rawValue)
        }
    }

    static func set(_ value: Bool, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    static func set(_ value: Int, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    static func set(_ value: Double, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    static func set(_ value: Date, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    static func bool(_ key: Key, default fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key.rawValue) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key.rawValue)
    }

    static func int(_ key: Key, default fallback: Int) -> Int {
        guard UserDefaults.standard.object(forKey: key.rawValue) != nil else { return fallback }
        return UserDefaults.standard.integer(forKey: key.rawValue)
    }

    static func date(_ key: Key) -> Date? {
        UserDefaults.standard.object(forKey: key.rawValue) as? Date
    }
}
