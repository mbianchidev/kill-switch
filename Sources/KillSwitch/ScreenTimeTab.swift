import SwiftUI

struct ScreenTimeTab: View {
    @ObservedObject private var monitor = ScreenTimeMonitor.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    activityCard
                    reminderCard
                    privacyCard
                    if let errorMessage = monitor.errorMessage {
                        errorCard(errorMessage)
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack {
            Image(systemName: "figure.walk.motion")
                .foregroundColor(Theme.screenTime)
            Text("Screen time")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(monitor.isActive ? Theme.screenTime : Color.white.opacity(0.3))
                    .frame(width: 7, height: 7)
                Text(monitor.isActive ? "Active now" : "Counting paused")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(monitor.isActive ? Theme.screenTime : .white.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    private var activityCard: some View {
        HStack(spacing: 24) {
            progressRing

            VStack(spacing: 12) {
                metricRow(
                    title: "Active today",
                    value: duration(monitor.activeSecondsToday),
                    detail: "Keyboard or pointer activity within the last five minutes"
                )
                Divider().overlay(Color.white.opacity(0.08))
                metricRow(
                    title: "Current stretch",
                    value: duration(monitor.currentStretchSeconds),
                    detail: activityDetail
                )
                Divider().overlay(Color.white.opacity(0.08))
                metricRow(
                    title: "Next break",
                    value: nextReminderValue,
                    detail: nextReminderDetail
                )
            }
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.screenTime.opacity(0.2)))
        )
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 12)
            Circle()
                .trim(from: 0, to: monitor.remindersEnabled ? max(0.002, monitor.reminderProgress) : 0)
                .stroke(
                    Theme.screenTime,
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 4) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.screenTime)
                Text(duration(monitor.currentStretchSeconds))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("CURRENT STRETCH")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(18)
        }
        .frame(width: 176, height: 176)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current screen time stretch")
        .accessibilityValue(duration(monitor.currentStretchSeconds))
    }

    private var reminderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Break reminder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                    Text("Get a native notification when an active stretch reaches the interval.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                Toggle("", isOn: $monitor.remindersEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.screenTime)
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reminder interval")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.85))
                    Text("The next future boundary is used when you change this setting.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                Picker("Reminder interval", selection: $monitor.reminderIntervalHours) {
                    ForEach(ScreenTimeMonitor.reminderHourRange, id: \.self) { hours in
                        Text("\(hours) \(hours == 1 ? "hour" : "hours")").tag(hours)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
                .disabled(!monitor.remindersEnabled)
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("End current stretch")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.85))
                    Text("Keeps today's total and restarts reminder progress.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                Button {
                    monitor.resetCurrentStretch()
                } label: {
                    Label("Reset stretch", systemImage: "figure.walk")
                }
                .buttonStyle(.bordered)
                .tint(Theme.screenTime)
                .disabled(monitor.currentStretchSeconds == 0)
            }

            if let lastReminderDate = monitor.lastReminderDate {
                Text("Last reminder: \(lastReminderDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.2)))
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 17))
                .foregroundColor(Theme.screenTime)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                Text("Private by design")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Text("KillSwitch stores only today's active seconds and the current stretch on this Mac. It does not collect app, website, keystroke, or pointer history.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                Text("Counting pauses after 5 minutes without input. A 10-minute idle period, screen lock, display sleep, or system sleep ends the stretch.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.screenTime.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.screenTime.opacity(0.16)))
        )
    }

    private func metricRow(title: String, value: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.42))
                    .textCase(.uppercase)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.38))
                    .lineLimit(2)
            }
            Spacer()
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.trailing)
        }
    }

    private func errorCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundColor(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }

    private var activityDetail: String {
        if monitor.isActive {
            return "Active input detected; this stretch is still growing."
        }
        if monitor.idleSeconds >= 10 * 60 {
            return "A break was detected and reminder progress restarted."
        }
        return "Counting is paused while input is idle."
    }

    private var nextReminderValue: String {
        guard let seconds = monitor.secondsUntilReminder else { return "Off" }
        return duration(seconds)
    }

    private var nextReminderDetail: String {
        monitor.remindersEnabled
            ? "A touch-grass reminder will fire after this much more active time."
            : "Enable reminders below to build progress toward a break."
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}
