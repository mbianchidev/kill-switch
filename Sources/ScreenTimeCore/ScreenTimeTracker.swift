import Foundation

public struct ScreenTimeSnapshot: Equatable {
    public var dayStart: Date
    public var activeSecondsToday: TimeInterval
    public var currentStretchSeconds: TimeInterval
    public var lastSampleDate: Date?

    public init(
        dayStart: Date,
        activeSecondsToday: TimeInterval = 0,
        currentStretchSeconds: TimeInterval = 0,
        lastSampleDate: Date? = nil
    ) {
        self.dayStart = dayStart
        self.activeSecondsToday = max(0, activeSecondsToday)
        self.currentStretchSeconds = max(0, currentStretchSeconds)
        self.lastSampleDate = lastSampleDate
    }
}

public struct ScreenTimeUpdate: Equatable {
    public let creditedSeconds: TimeInterval
    public let didResetStretch: Bool
    public let shouldRemind: Bool
    public let isActive: Bool

    public init(
        creditedSeconds: TimeInterval,
        didResetStretch: Bool,
        shouldRemind: Bool,
        isActive: Bool
    ) {
        self.creditedSeconds = creditedSeconds
        self.didResetStretch = didResetStretch
        self.shouldRemind = shouldRemind
        self.isActive = isActive
    }
}

public struct ScreenTimeTracker {
    public static let activeIdleThreshold: TimeInterval = 5 * 60
    public static let breakIdleThreshold: TimeInterval = 10 * 60
    public static let maximumSampleGap: TimeInterval = 2 * 60

    public private(set) var snapshot: ScreenTimeSnapshot

    public init(
        snapshot: ScreenTimeSnapshot? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        var initial = snapshot ?? ScreenTimeSnapshot(dayStart: calendar.startOfDay(for: now))
        initial.activeSecondsToday = max(0, initial.activeSecondsToday)
        initial.currentStretchSeconds = max(0, initial.currentStretchSeconds)

        let canReconcileDay = initial.lastSampleDate.map { $0 <= now } ?? true
        if canReconcileDay, !calendar.isDate(initial.dayStart, inSameDayAs: now) {
            initial.dayStart = calendar.startOfDay(for: now)
            initial.activeSecondsToday = 0
        }

        self.snapshot = initial
    }

    @discardableResult
    public mutating func sample(
        at now: Date,
        idleSeconds: TimeInterval,
        reminderInterval: TimeInterval?,
        calendar: Calendar = .current
    ) -> ScreenTimeUpdate {
        let idleSeconds = max(0, idleSeconds)
        let isActive = idleSeconds < Self.activeIdleThreshold
        guard let previousSample = snapshot.lastSampleDate else {
            rollDayIfNeeded(at: now, calendar: calendar)
            snapshot.lastSampleDate = now
            return ScreenTimeUpdate(
                creditedSeconds: 0,
                didResetStretch: false,
                shouldRemind: false,
                isActive: isActive
            )
        }

        let elapsed = now.timeIntervalSince(previousSample)
        guard elapsed > 0 else {
            return ScreenTimeUpdate(
                creditedSeconds: 0,
                didResetStretch: false,
                shouldRemind: false,
                isActive: isActive
            )
        }
        rollDayIfNeeded(at: now, calendar: calendar)
        snapshot.lastSampleDate = now

        if idleSeconds >= Self.breakIdleThreshold || elapsed >= Self.breakIdleThreshold {
            let didReset = snapshot.currentStretchSeconds > 0
            snapshot.currentStretchSeconds = 0
            return ScreenTimeUpdate(
                creditedSeconds: 0,
                didResetStretch: didReset,
                shouldRemind: false,
                isActive: isActive
            )
        }

        guard isActive, elapsed <= Self.maximumSampleGap else {
            return ScreenTimeUpdate(
                creditedSeconds: 0,
                didResetStretch: false,
                shouldRemind: false,
                isActive: isActive
            )
        }

        let previousStretch = snapshot.currentStretchSeconds
        snapshot.currentStretchSeconds += elapsed

        let currentDayStart = calendar.startOfDay(for: now)
        let creditedToday = max(0, now.timeIntervalSince(max(previousSample, currentDayStart)))
        snapshot.activeSecondsToday += min(elapsed, creditedToday)

        return ScreenTimeUpdate(
            creditedSeconds: elapsed,
            didResetStretch: false,
            shouldRemind: crossedReminderBoundary(
                from: previousStretch,
                to: snapshot.currentStretchSeconds,
                interval: reminderInterval
            ),
            isActive: true
        )
    }

    @discardableResult
    public mutating func endStretch(
        at now: Date,
        calendar: Calendar = .current
    ) -> ScreenTimeUpdate {
        let didReset = snapshot.currentStretchSeconds > 0
        snapshot.currentStretchSeconds = 0
        if snapshot.lastSampleDate.map({ $0 <= now }) ?? true {
            rollDayIfNeeded(at: now, calendar: calendar)
            snapshot.lastSampleDate = now
        }
        return ScreenTimeUpdate(
            creditedSeconds: 0,
            didResetStretch: didReset,
            shouldRemind: false,
            isActive: false
        )
    }

    private mutating func rollDayIfNeeded(at now: Date, calendar: Calendar) {
        guard !calendar.isDate(snapshot.dayStart, inSameDayAs: now) else { return }
        snapshot.dayStart = calendar.startOfDay(for: now)
        snapshot.activeSecondsToday = 0
    }

    private func crossedReminderBoundary(
        from previous: TimeInterval,
        to current: TimeInterval,
        interval: TimeInterval?
    ) -> Bool {
        guard let interval, interval > 0 else { return false }
        return Int(previous / interval) < Int(current / interval)
    }
}
