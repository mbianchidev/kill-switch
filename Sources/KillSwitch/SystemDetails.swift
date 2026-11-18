import AppKit
import InstallCore
import SwiftUI
import SystemMetricsCore
import TableQueryCore
import os

private enum VolumeFields {
    static let name = TableField<SystemVolume>.text("name", title: "Volume", aliases: ["volume"]) { $0.name }
    static let path = TableField<SystemVolume>.text("path", title: "Mount point", aliases: ["mount"]) { $0.path }
    static let format = TableField<SystemVolume>.text("format", title: "Format", aliases: ["filesystem"]) { $0.format }
    static let used = TableField<SystemVolume>.number("used", title: "Used", unit: .percent) {
        (volume: SystemVolume) -> Double? in volume.usedFraction.map { $0 * 100 }
    }
    static let available = TableField<SystemVolume>.number("available", title: "Available", aliases: ["free"], unit: .bytes) {
        (volume: SystemVolume) -> Decimal? in volume.availableBytes.map { Decimal($0) }
    }
    static let total = TableField<SystemVolume>.number("total", title: "Capacity", aliases: ["size"], unit: .bytes) {
        (volume: SystemVolume) -> Decimal? in volume.totalBytes.map { Decimal($0) }
    }
    static let isInternal = TableField<SystemVolume>.boolean("internal", title: "Internal") { $0.isInternal }
    static let removable = TableField<SystemVolume>.boolean("removable", title: "Removable") { $0.isRemovable }
    static let all = [name, path, format, used, available, total, isInternal, removable]
}

private enum DisplayFields {
    static let name = TableField<SystemDisplay>.text("name", title: "Display") { $0.name }
    static let resolution = TableField<SystemDisplay>.text("resolution", title: "Resolution") { $0.resolution }
    static let pixels = TableField<SystemDisplay>.text("pixels", title: "Pixels") { $0.pixels }
    static let main = TableField<SystemDisplay>.boolean("main", title: "Main") { $0.isMain }
    static let builtIn = TableField<SystemDisplay>.boolean("builtIn", title: "Built-in", aliases: ["internal"]) { $0.isBuiltIn }
    static let all = [name, resolution, pixels, main, builtIn]
}

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
    let tableStates: TableStateStore
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
        .onAppear { if allowsOperations { monitor.refresh() } }
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
        if !snapshot.volumes.isEmpty {
            EmbeddedDataTable(
                snapshot.volumes, fields: VolumeFields.all, sortedBy: TableComparator(field: VolumeFields.name),
                state: tableStates, key: "volumes",
                identity: \.id, prompt: "Search volumes, or used > 90%"
            ) {
                TableColumn("Volume", sortUsing: TableComparator(field: VolumeFields.name)) { volume in
                    Text(volume.name).font(.system(size: 12, weight: .medium)).copyOnClick(volume.name, label: "volume name")
                }
                .width(min: 100, ideal: 150)
                TableColumn("Mount point", sortUsing: TableComparator(field: VolumeFields.path)) { volume in
                    Text(volume.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .copyOnClick(volume.path, label: "mount point")
                }
                .width(min: 80, ideal: 160)
                TableColumn("Format", sortUsing: TableComparator(field: VolumeFields.format)) { Text($0.format ?? "—") }
                    .width(min: 50, ideal: 70)
                TableColumn("Used", sortUsing: TableComparator(field: VolumeFields.used)) { usage($0) }
                    .width(min: 80, ideal: 130)
                TableColumn("Available", sortUsing: TableComparator(field: VolumeFields.available)) { volume in
                    Text(volume.availableBytes.map(formatBytes) ?? "—").font(.system(size: 11, design: .monospaced))
                }
                .width(min: 60, ideal: 90)
                TableColumn("Capacity", sortUsing: TableComparator(field: VolumeFields.total)) { volume in
                    Text(volume.totalBytes.map(formatBytes) ?? "—").font(.system(size: 11, design: .monospaced))
                }
                .width(min: 60, ideal: 90)
                TableColumn("Location", sortUsing: TableComparator(field: VolumeFields.isInternal)) { volume in
                    Text(volume.isInternal.map { $0 ? "Internal" : "External" } ?? "—")
                }
                .width(min: 56, ideal: 75)
            }
        }
        Divider()
        Text("Displays").font(.system(size: 12, weight: .semibold))
        if (hardware?.displays ?? []).isEmpty {
            Text("No online displays were reported.").foregroundColor(.secondary)
        }
        if let displays = hardware?.displays, !displays.isEmpty {
            EmbeddedDataTable(
                displays, fields: DisplayFields.all, sortedBy: TableComparator(field: DisplayFields.main, order: .reverse),
                state: tableStates, key: "displays",
                identity: \.id, prompt: "Search displays, or builtIn = no"
            ) {
                TableColumn("Display", sortUsing: TableComparator(field: DisplayFields.name)) { display in
                    Text(display.name + (display.isMain ? " (main)" : "")).copyOnClick(display.name, label: "display name")
                }
                .width(min: 100, ideal: 180)
                TableColumn("Resolution", sortUsing: TableComparator(field: DisplayFields.resolution)) { display in
                    Text(display.resolution ?? "—").font(.system(size: 11, design: .monospaced))
                }
                .width(min: 100, ideal: 180)
                TableColumn("Pixels", sortUsing: TableComparator(field: DisplayFields.pixels)) { display in
                    Text(display.pixels ?? "—").font(.system(size: 11, design: .monospaced))
                }
                .width(min: 80, ideal: 110)
                TableColumn("Type", sortUsing: TableComparator(field: DisplayFields.builtIn)) { display in
                    Text(display.isBuiltIn ? "Built-in" : "External")
                }
                .width(min: 56, ideal: 75)
            }
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

    @ViewBuilder
    private func usage(_ volume: SystemVolume) -> some View {
        if let fraction = volume.usedFraction {
            HStack(spacing: 6) {
                ProgressView(value: min(1, max(0, fraction)))
                    .tint(fraction > 0.9 ? .orange : Theme.diskOccupied)
                Text(String(format: "%.0f%%", fraction * 100)).font(.system(size: 11, design: .monospaced))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(volume.name) used space")
            .accessibilityValue(String(format: "%.0f%%", fraction * 100))
        } else {
            Text("Unavailable").foregroundColor(.secondary)
        }
    }
}
