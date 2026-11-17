import AppKit
import InstallCore
import SwiftUI
import SystemMetricsCore
import os

struct SystemDetailsSnapshot: Equatable {
    var hardware: SystemProfilerHardware?
    var identity: SystemIdentity?
    var volumes: [SystemVolume] = []
    var warnings: [String] = []
    var date = Date()
}

/// Collects slower, mostly static system details when the System page opens or on request.
@MainActor
final class SystemDetailsMonitor: ObservableObject {
    static let shared = SystemDetailsMonitor()

    @Published private(set) var snapshot: SystemDetailsSnapshot?
    @Published private(set) var isLoading = false
    private let queue = DispatchQueue(label: "killswitch.system-details", qos: .utility)
    private let logger = Logger(subsystem: "com.killswitch.app", category: "system-details")

    private init() {}

    func loadIfNeeded() {
        if snapshot == nil { refresh() }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        queue.async { [weak self] in
            var snapshot = SystemDetailsSnapshot()
            do {
                let result = try CommandRunner.run("/usr/sbin/system_profiler", arguments: SystemDetailsParser.profilerArguments,
                                                   outputDecoding: .lossyUTF8)
                guard result.succeeded else {
                    throw CommandRunnerError.commandFailed(executable: "system_profiler", status: result.status,
                                                           message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                snapshot.hardware = try SystemDetailsParser.parseProfiler(Data(result.standardOutput.utf8))
            } catch {
                snapshot.warnings.append("Model and display details are unavailable: \(error.localizedDescription)")
            }
            let identity = SystemDetailsReader.identity()
            snapshot.identity = identity
            snapshot.warnings += identity.warnings
            snapshot.volumes = SystemDetailsReader.volumes()
            snapshot.date = Date()
            DispatchQueue.main.async {
                guard let self else { return }
                for warning in snapshot.warnings { self.logger.error("\(warning, privacy: .public)") }
                self.snapshot = snapshot
                self.isLoading = false
            }
        }
    }
}

#if KILLSWITCH_PERFORMANCE_PROBE
extension SystemDetailsMonitor {
    /// Publishes fictional details in memory only; no identifiers are read.
    func publishPerformanceFixture() {
        snapshot = SystemDetailsSnapshot(
            hardware: SystemProfilerHardware(
                modelName: "Synthetic Mac", modelIdentifier: "Synthetic1,1", modelNumber: "SYN001", displays: [
                    SystemDisplay(index: 0, name: "Built-in Display", resolution: "1512 x 982 @ 120.00Hz",
                                  pixels: "3024 x 1964", isMain: true, isBuiltIn: true)
                ]
            ),
            identity: SystemIdentity(
                computerName: "Synthetic Mac", localHostName: "synthetic-mac.local",
                bootTime: Date(timeIntervalSinceNow: -86_400), serialNumber: "SYNTHETIC0001",
                hardwareUUID: "00000000-0000-0000-0000-000000000001", warnings: []
            ),
            volumes: [SystemVolume(name: "Synthetic HD", path: "/", format: "APFS", totalBytes: 1_000_000_000_000,
                                   availableBytes: 400_000_000_000, isInternal: true, isRemovable: false)]
        )
    }
}
#endif

struct SystemDetailsCard: View {
    @ObservedObject var monitor: SystemDetailsMonitor
    @Environment(\.allowsLiveOperations) private var allowsOperations
    @State private var revealIdentifiers = false
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("System details", systemImage: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.accent)
                Spacer()
                if monitor.isLoading { ProgressView().controlSize(.small) }
                Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(monitor.isLoading || !allowsOperations)
                    .accessibilityLabel("Refresh system details")
            }
            if let snapshot = monitor.snapshot {
                details(snapshot)
            } else {
                Text(monitor.isLoading ? "Collecting system details" : "System details have not been read yet.")
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
        .onAppear { if allowsOperations { monitor.loadIfNeeded() } }
    }

    @ViewBuilder
    private func details(_ snapshot: SystemDetailsSnapshot) -> some View {
        ForEach(snapshot.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundColor(.orange)
        }
        let hardware = snapshot.hardware
        let identity = snapshot.identity
        row("Model name", [hardware?.modelName, hardware?.modelIdentifier].compactMap { $0 }.joined(separator: " · "))
        row("Model number", hardware?.modelNumber)
        row("Computer name", identity?.computerName)
        row("Local hostname", identity?.localHostName)
        row("Booted", identity?.bootTime.map { $0.formatted(date: .abbreviated, time: .shortened) })
        identifierRow("Serial number", identity?.serialNumber)
        identifierRow("Hardware UUID", identity?.hardwareUUID)
        Divider()
        Text("Storage").font(.system(size: 12, weight: .semibold))
        if snapshot.volumes.isEmpty {
            Text("No mounted volumes were reported.").foregroundColor(.secondary)
        }
        ForEach(snapshot.volumes) { volume in
            volumeRow(volume)
        }
        Divider()
        Text("Displays").font(.system(size: 12, weight: .semibold))
        if (hardware?.displays ?? []).isEmpty {
            Text("No online displays were reported.").foregroundColor(.secondary)
        }
        ForEach(hardware?.displays ?? []) { display in
            row(display.name + (display.isMain ? " (main)" : ""),
                [display.resolution, display.pixels.map { "\($0) pixels" }, display.isBuiltIn ? "built-in" : "external"]
                    .compactMap { $0 }.joined(separator: " · "))
        }
        Text("Read \(snapshot.date.formatted(date: .omitted, time: .standard)) from system_profiler, IOKit, and volume information. The serial number and hardware UUID identify this Mac; they stay hidden until you show them and are never stored.")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
    }

    private func row(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "Unavailable")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(value?.isEmpty == false ? .primary : .secondary)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private func identifierRow(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                if let value {
                    Text(revealIdentifiers ? value : String(repeating: "•", count: min(value.count, 12)))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel(revealIdentifiers ? value : "Hidden")
                    Button(revealIdentifiers ? "Hide" : "Show") { revealIdentifiers.toggle() }
                        .controlSize(.small)
                        .accessibilityLabel("\(revealIdentifiers ? "Hide" : "Show") identifiers")
                    Button(copied == label ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                        copied = label
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Copy \(label.lowercased())")
                } else {
                    Text("Unavailable").foregroundColor(.secondary)
                }
            }
        }
        .font(.system(size: 12))
    }

    private func volumeRow(_ volume: SystemVolume) -> some View {
        let fraction = volume.totalBytes.flatMap { total in
            volume.usedBytes.map { total > 0 ? Double($0) / Double(total) : 0 }
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(volume.name).font(.system(size: 12, weight: .medium))
                Text([volume.path, volume.format, volume.isInternal == false ? "external" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Text(capacityText(volume)).font(.system(size: 11, design: .monospaced))
            }
            if let fraction {
                ProgressView(value: min(1, max(0, fraction)))
                    .tint(fraction > 0.9 ? .orange : Theme.diskOccupied)
                    .accessibilityLabel("\(volume.name) used space")
                    .accessibilityValue(String(format: "%.0f%%", fraction * 100))
            }
        }
    }

    private func capacityText(_ volume: SystemVolume) -> String {
        guard let total = volume.totalBytes else { return "Capacity unavailable" }
        guard let available = volume.availableBytes else { return "\(formatBytes(total)) total" }
        return "\(formatBytes(available)) available of \(formatBytes(total))"
    }
}
