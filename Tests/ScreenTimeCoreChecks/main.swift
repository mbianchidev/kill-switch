import Darwin
import Foundation
import ScreenTimeCore

@main
struct ScreenTimeCoreChecks {
    private static var failures: [String] = []
    private static var checkCount = 0

    private static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func main() {
        checkActiveAccumulation()
        checkIdlePauseAndReset()
        checkSamplingGapHandling()
        checkDayRollover()
        checkReminderBoundaries()
        checkIntervalChangeDoesNotBackfire()
        checkOutOfOrderSamples()
        checkRestartGapAndForcedBreak()

        if failures.isEmpty {
            print("ScreenTimeCoreChecks: \(checkCount) checks passed")
            return
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        fputs("ScreenTimeCoreChecks: \(failures.count) of \(checkCount) checks failed\n", stderr)
        exit(EXIT_FAILURE)
    }

    private static func checkActiveAccumulation() {
        let start = date(2026, 7, 16, 12, 0, 0)
        var tracker = ScreenTimeTracker(now: start, calendar: calendar)

        let first = tracker.sample(
            at: start,
            idleSeconds: 0,
            reminderInterval: nil,
            calendar: calendar
        )
        let second = tracker.sample(
            at: start.addingTimeInterval(60),
            idleSeconds: 10,
            reminderInterval: nil,
            calendar: calendar
        )

        check(first.creditedSeconds == 0, "first sample establishes a baseline")
        check(second.creditedSeconds == 60, "active sample credits elapsed time")
        check(tracker.snapshot.activeSecondsToday == 60, "daily active time accumulates")
        check(tracker.snapshot.currentStretchSeconds == 60, "active stretch accumulates")
    }

    private static func checkIdlePauseAndReset() {
        let start = date(2026, 7, 16, 12, 0, 0)
        var tracker = ScreenTimeTracker(
            snapshot: ScreenTimeSnapshot(
                dayStart: calendar.startOfDay(for: start),
                activeSecondsToday: 600,
                currentStretchSeconds: 600,
                lastSampleDate: start
            ),
            now: start,
            calendar: calendar
        )

        let paused = tracker.sample(
            at: start.addingTimeInterval(60),
            idleSeconds: 6 * 60,
            reminderInterval: nil,
            calendar: calendar
        )
        check(paused.creditedSeconds == 0, "five minutes idle pauses active-time credit")
        check(tracker.snapshot.currentStretchSeconds == 600, "short idle pause preserves stretch")

        let reset = tracker.sample(
            at: start.addingTimeInterval(120),
            idleSeconds: 10 * 60,
            reminderInterval: nil,
            calendar: calendar
        )
        check(reset.didResetStretch, "ten minutes idle resets the stretch")
        check(tracker.snapshot.currentStretchSeconds == 0, "idle reset clears stretch")
        check(tracker.snapshot.activeSecondsToday == 600, "idle time is not added to daily total")
    }

    private static func checkSamplingGapHandling() {
        let start = date(2026, 7, 16, 12, 0, 0)
        var tracker = ScreenTimeTracker(
            snapshot: ScreenTimeSnapshot(
                dayStart: calendar.startOfDay(for: start),
                activeSecondsToday: 300,
                currentStretchSeconds: 300,
                lastSampleDate: start
            ),
            now: start,
            calendar: calendar
        )

        let capped = tracker.sample(
            at: start.addingTimeInterval(3 * 60),
            idleSeconds: 0,
            reminderInterval: nil,
            calendar: calendar
        )
        check(capped.creditedSeconds == 0, "large timer delay is not credited as active time")
        check(tracker.snapshot.currentStretchSeconds == 300, "sub-break timer delay preserves stretch")

        let reset = tracker.sample(
            at: start.addingTimeInterval(13 * 60),
            idleSeconds: 0,
            reminderInterval: nil,
            calendar: calendar
        )
        check(reset.didResetStretch, "ten-minute sampling gap resets stale stretch")
        check(tracker.snapshot.currentStretchSeconds == 0, "long timer gap clears stretch")
    }

    private static func checkDayRollover() {
        let start = date(2026, 7, 16, 23, 59, 0)
        var tracker = ScreenTimeTracker(now: start, calendar: calendar)
        _ = tracker.sample(at: start, idleSeconds: 0, reminderInterval: nil, calendar: calendar)
        _ = tracker.sample(
            at: start.addingTimeInterval(30),
            idleSeconds: 0,
            reminderInterval: nil,
            calendar: calendar
        )
        _ = tracker.sample(
            at: start.addingTimeInterval(90),
            idleSeconds: 0,
            reminderInterval: nil,
            calendar: calendar
        )

        check(tracker.snapshot.activeSecondsToday == 30, "new day receives only post-midnight active time")
        check(tracker.snapshot.currentStretchSeconds == 90, "midnight does not end an active stretch")
        check(
            tracker.snapshot.dayStart == date(2026, 7, 17, 0, 0, 0),
            "daily bucket advances at midnight"
        )
    }

    private static func checkReminderBoundaries() {
        let start = date(2026, 7, 16, 12, 0, 0)
        var tracker = ScreenTimeTracker(
            snapshot: ScreenTimeSnapshot(
                dayStart: calendar.startOfDay(for: start),
                activeSecondsToday: 3_590,
                currentStretchSeconds: 3_590,
                lastSampleDate: start
            ),
            now: start,
            calendar: calendar
        )

        let crossing = tracker.sample(
            at: start.addingTimeInterval(20),
            idleSeconds: 0,
            reminderInterval: 3_600,
            calendar: calendar
        )
        let sameBucket = tracker.sample(
            at: start.addingTimeInterval(40),
            idleSeconds: 0,
            reminderInterval: 3_600,
            calendar: calendar
        )

        check(crossing.shouldRemind, "crossing an hourly boundary fires a reminder")
        check(!sameBucket.shouldRemind, "only one reminder fires per interval boundary")
    }

    private static func checkIntervalChangeDoesNotBackfire() {
        let start = date(2026, 7, 16, 12, 0, 0)
        var tracker = ScreenTimeTracker(
            snapshot: ScreenTimeSnapshot(
                dayStart: calendar.startOfDay(for: start),
                activeSecondsToday: 5_400,
                currentStretchSeconds: 5_400,
                lastSampleDate: start
            ),
            now: start,
            calendar: calendar
        )

        let afterShrink = tracker.sample(
            at: start.addingTimeInterval(30),
            idleSeconds: 0,
            reminderInterval: 3_600,
            calendar: calendar
        )
        check(!afterShrink.shouldRemind, "shorter interval does not fire a stale reminder")

        let nearBoundary = start.addingTimeInterval(60)
        tracker = ScreenTimeTracker(
            snapshot: ScreenTimeSnapshot(
                dayStart: calendar.startOfDay(for: start),
                activeSecondsToday: 7_190,
                currentStretchSeconds: 7_190,
                lastSampleDate: nearBoundary
            ),
            now: nearBoundary,
            calendar: calendar
        )
        let nextBoundary = tracker.sample(
            at: nearBoundary.addingTimeInterval(20),
            idleSeconds: 0,
            reminderInterval: 3_600,
            calendar: calendar
        )
        check(nextBoundary.shouldRemind, "changed interval fires at the next future boundary")
    }

    private static func checkRestartGapAndForcedBreak() {
        let start = date(2026, 7, 16, 12, 0, 0)
        let persisted = ScreenTimeSnapshot(
            dayStart: calendar.startOfDay(for: start),
            activeSecondsToday: 4_000,
            currentStretchSeconds: 4_000,
            lastSampleDate: start
        )
        let relaunchedAt = start.addingTimeInterval(3_600)
        var tracker = ScreenTimeTracker(snapshot: persisted, now: relaunchedAt, calendar: calendar)
        let restart = tracker.sample(
            at: relaunchedAt,
            idleSeconds: 0,
            reminderInterval: 3_600,
            calendar: calendar
        )

        check(restart.didResetStretch, "long restart gap clears stale reminder progress")
        check(restart.isActive, "restart reconciliation preserves current activity status")
        check(tracker.snapshot.activeSecondsToday == 4_000, "restart gap is not counted as active")

        tracker = ScreenTimeTracker(snapshot: persisted, now: start, calendar: calendar)
        let forced = tracker.endStretch(at: start.addingTimeInterval(5), calendar: calendar)
        check(forced.didResetStretch, "sleep or lock can force a stretch reset")
        check(tracker.snapshot.currentStretchSeconds == 0, "forced break clears the stretch")
    }

    private static func checkOutOfOrderSamples() {
        let start = date(2026, 7, 16, 12, 0, 0)
        var tracker = ScreenTimeTracker(
            snapshot: ScreenTimeSnapshot(
                dayStart: calendar.startOfDay(for: start),
                activeSecondsToday: 60,
                currentStretchSeconds: 60,
                lastSampleDate: start
            ),
            now: start,
            calendar: calendar
        )

        let backwards = tracker.sample(
            at: start.addingTimeInterval(-10),
            idleSeconds: 0,
            reminderInterval: nil,
            calendar: calendar
        )
        check(backwards.creditedSeconds == 0, "out-of-order sample is not credited")
        check(tracker.snapshot.lastSampleDate == start, "out-of-order sample does not move the baseline backwards")

        let forward = tracker.sample(
            at: start.addingTimeInterval(10),
            idleSeconds: 0,
            reminderInterval: nil,
            calendar: calendar
        )
        check(forward.creditedSeconds == 10, "next valid sample uses the last accepted baseline")
    }

    private static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ second: Int
    ) -> Date {
        calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )
        )!
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checkCount += 1
        if !condition() {
            failures.append(message)
        }
    }
}
