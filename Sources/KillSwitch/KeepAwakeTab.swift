import KeepAwakeCore
import SwiftUI

struct KeepAwakeTab: View {
    @ObservedObject private var manager = KeepAwakeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statusSection
                    sessionSection
                    advancedSection
                    if let errorMessage = manager.errorMessage {
                        errorSection(errorMessage)
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack {
            Image(systemName: "cup.and.saucer.fill")
                .foregroundColor(.cyan)
            Text("Keep awake")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Text(manager.activeDuration == nil ? "Inactive" : "Active")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(manager.activeDuration == nil ? .white.opacity(0.45) : .cyan)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    private var statusSection: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: manager.activeDuration == nil ? "moon.zzz.fill" : "bolt.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(statusColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(manager.activeDuration == nil ? "Normal sleep behavior" : "Keeping this Mac awake")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(statusDetail)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            if manager.activeDuration != nil {
                Button("Deactivate") { manager.deactivate() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(statusColor.opacity(manager.activeDuration == nil ? 0.06 : 0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(statusColor.opacity(0.22), lineWidth: 1)
                )
        )
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default session")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Duration")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.45))
                    Picker("", selection: $manager.preferredDuration) {
                        ForEach(KeepAwakeDuration.allCases, id: \.self) { duration in
                            Text(duration.label).tag(duration)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }

                Spacer()

                Button {
                    manager.activatePreferred()
                } label: {
                    Label(
                        manager.activeDuration == nil ? "Start keeping awake" : "Restart with defaults",
                        systemImage: "bolt.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }

            Text("This duration is used by the Start button and automatic launch activation. Menu-bar choices still use the duration you select there.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
        .sectionCard()
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Advanced settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Button {
                    manager.resetToDefaults()
                } label: {
                    Label("Reset to defaults", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.white.opacity(0.65))
            }

            Toggle(isOn: $manager.keepDisplayAwake) {
                preferenceLabel(
                    title: "Keep the display awake",
                    detail: "Turn this off to keep background work running while allowing the screen to dim and sleep."
                )
            }
            .toggleStyle(.switch)
            .tint(.cyan)

            Divider().overlay(Color.white.opacity(0.08))

            Toggle(isOn: $manager.activateOnLaunch) {
                preferenceLabel(
                    title: "Activate when KillSwitch launches",
                    detail: "Starts a session using the default duration and display setting above."
                )
            }
            .toggleStyle(.switch)
            .tint(.cyan)

            Text("The Mac always stays awake while a session is active. Display sleep is the optional part.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
        .sectionCard()
    }

    private func preferenceLabel(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private func errorSection(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundColor(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }

    private var statusColor: Color {
        manager.activeDuration == nil ? .gray : .cyan
    }

    private var statusDetail: String {
        guard let duration = manager.activeDuration else {
            return "System and display follow macOS sleep settings."
        }
        let mode = manager.activeMode?.label ?? manager.preferredMode.label
        return "\(duration.label) · \(mode)"
    }
}

private extension View {
    func sectionCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.2)))
    }
}
