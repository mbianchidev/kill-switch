import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

extension Notification.Name {
    static let showDiagnosticsTab = Notification.Name("KillSwitch.showDiagnosticsTab")
}

enum DiagnosticError: LocalizedError {
    case cancelled
    case commandFailed(String)
    case outputMissing(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The administrator request was cancelled."
        case let .commandFailed(message):
            return message
        case let .outputMissing(message):
            return message
        }
    }
}

final class DiagnosticsController: ObservableObject {
    static let shared = DiagnosticsController()

    @Published private(set) var isGeneratingSpindump = false
    @Published private(set) var isRunningSystemDiagnostics = false
    @Published private(set) var spindumpPreview = ""
    @Published private(set) var spindumpURL: URL?
    @Published private(set) var sysdiagnoseURL: URL?
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?

    private let workQueue = DispatchQueue(label: "killswitch.diagnostics", qos: .userInitiated)
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.killswitch.app", category: "diagnostics")
    private let previewLimit = 2 * 1_024 * 1_024

    private init() {}

    func generateSpindump() {
        guard !isGeneratingSpindump, !isRunningSystemDiagnostics else { return }

        isGeneratingSpindump = true
        errorMessage = nil
        statusMessage = "Sampling the system for 10 seconds…"

        workQueue.async { [weak self] in
            guard let self else { return }

            do {
                let directory = try self.outputDirectory()
                let filename = "Spindump-\(self.timestamp()).txt"
                let outputURL = directory.appendingPathComponent(filename)
                let quotedOutput = CommandRunner.shellQuote(outputURL.path)
                let owner = "\(getuid()):\(getgid())"
                let command = [
                    "/usr/sbin/spindump -noTarget 10 10 -o \(quotedOutput) -noBinary",
                    "status=$?",
                    "if [ -e \(quotedOutput) ]; then /usr/sbin/chown \(owner) \(quotedOutput); /bin/chmod 600 \(quotedOutput); fi",
                    "exit $status"
                ].joined(separator: "; ")

                try self.runPrivileged(command)
                guard self.fileManager.fileExists(atPath: outputURL.path) else {
                    throw DiagnosticError.outputMissing("Spindump finished without creating a report.")
                }
                let preview = try self.readPreview(from: outputURL)

                DispatchQueue.main.async {
                    self.spindumpURL = outputURL
                    self.spindumpPreview = preview
                    self.statusMessage = "Spindump saved to \(outputURL.path)."
                    self.isGeneratingSpindump = false
                }
            } catch {
                self.publishFailure(error, operation: "Spindump")
            }
        }
    }

    func runSystemDiagnostics() {
        guard !isRunningSystemDiagnostics, !isGeneratingSpindump else { return }

        isRunningSystemDiagnostics = true
        errorMessage = nil
        statusMessage = "Running sysdiagnose. This can take several minutes…"

        workQueue.async { [weak self] in
            guard let self else { return }

            do {
                let rootDirectory = try self.outputDirectory()
                let runName = "Sysdiagnose-\(self.timestamp())"
                let runDirectory = rootDirectory.appendingPathComponent(runName, isDirectory: true)
                try self.fileManager.createDirectory(
                    at: runDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )

                let archiveName = "KillSwitch-\(runName)"
                let quotedDirectory = CommandRunner.shellQuote(runDirectory.path)
                let quotedArchive = CommandRunner.shellQuote(archiveName)
                let owner = "\(getuid()):\(getgid())"
                let command = [
                    "/usr/bin/sysdiagnose -f \(quotedDirectory) -A \(quotedArchive) -b",
                    "status=$?",
                    "/usr/sbin/chown -R \(owner) \(quotedDirectory)",
                    "exit $status"
                ].joined(separator: "; ")

                try self.runPrivileged(command)
                guard let outputURL = self.newestOutput(in: runDirectory) else {
                    throw DiagnosticError.outputMissing(
                        "System diagnostics finished without creating an archive in \(runDirectory.path)."
                    )
                }

                DispatchQueue.main.async {
                    self.sysdiagnoseURL = outputURL
                    self.statusMessage = "System diagnostics saved to \(outputURL.path)."
                    self.isRunningSystemDiagnostics = false
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
            } catch {
                self.publishFailure(error, operation: "System diagnostics")
            }
        }
    }

    func reloadSpindumpPreview() {
        guard let spindumpURL else { return }

        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let preview = try self.readPreview(from: spindumpURL)
                DispatchQueue.main.async {
                    self.spindumpPreview = preview
                    self.statusMessage = "Spindump preview refreshed."
                    self.errorMessage = nil
                }
            } catch {
                self.publishFailure(error, operation: "Spindump preview")
            }
        }
    }

    func saveSpindumpAs() {
        guard let spindumpURL else { return }

        let panel = NSSavePanel()
        panel.title = "Save Spindump"
        panel.nameFieldStringValue = spindumpURL.lastPathComponent
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if destination.standardizedFileURL == spindumpURL.standardizedFileURL {
                statusMessage = "Spindump is already saved at \(destination.path)."
                return
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: spindumpURL, to: destination)
            statusMessage = "Spindump saved to \(destination.path)."
            errorMessage = nil
        } catch {
            errorMessage = "Could not save the spindump: \(error.localizedDescription)"
        }
    }

    func revealSpindump() {
        guard let spindumpURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([spindumpURL])
    }

    func revealSystemDiagnostics() {
        guard let sysdiagnoseURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([sysdiagnoseURL])
    }

    func revealOutputFolder() {
        do {
            NSWorkspace.shared.open(try outputDirectory())
        } catch {
            errorMessage = "Could not open the diagnostics folder: \(error.localizedDescription)"
        }
    }

    private func outputDirectory() throws -> URL {
        let base = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let directory = base.appendingPathComponent("KillSwitch Diagnostics", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func runPrivileged(_ command: String) throws {
        let script = "do shell script \(CommandRunner.appleScriptLiteral(command)) with administrator privileges"
        let result = try CommandRunner.run("/usr/bin/osascript", arguments: ["-e", script])
        guard result.succeeded else {
            let message = [result.standardError, result.standardOutput]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.localizedCaseInsensitiveContains("user canceled") || message.contains("-128") {
                throw DiagnosticError.cancelled
            }
            throw DiagnosticError.commandFailed(
                message.isEmpty
                    ? "The privileged diagnostic command exited with status \(result.status)."
                    : message
            )
        }
    }

    private func readPreview(from url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let data = try handle.read(upToCount: previewLimit) ?? Data()
        var preview = String(decoding: data, as: UTF8.self)
        let size = (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? data.count
        if size > data.count {
            preview += "\n\n[Preview truncated at 2 MB. Save or reveal the report to view the complete file.]"
        }
        return preview
    }

    private func newestOutput(in directory: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidates: [(url: URL, date: Date)] = []
        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true
            else {
                continue
            }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }
        return candidates.max(by: { $0.date < $1.date })?.url
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func publishFailure(_ error: Error, operation: String) {
        logger.error("\(operation) failed: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.errorMessage = "\(operation) failed: \(error.localizedDescription)"
            self.statusMessage = nil
            self.isGeneratingSpindump = false
            self.isRunningSystemDiagnostics = false
        }
    }
}

struct DiagnosticsTab: View {
    @ObservedObject var controller: DiagnosticsController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    systemDiagnosticsCard
                    spindumpCard
                }
                .padding(16)
            }
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack {
            Label("Diagnostics", systemImage: "stethoscope")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Button("Open diagnostics folder") {
                controller.revealOutputFolder()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    private var systemDiagnosticsCard: some View {
        diagnosticCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.orange)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 7) {
                    Text("System Diagnostics")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Text(
                        "Collect a full macOS sysdiagnose archive with logs, system state, a spindump, storage, and network details. An administrator prompt appears and collection can take several minutes."
                    )
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.58))

                    HStack(spacing: 10) {
                        Button {
                            controller.runSystemDiagnostics()
                        } label: {
                            if controller.isRunningSystemDiagnostics {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Run System Diagnostics", systemImage: "play.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                        .disabled(controller.isGeneratingSpindump || controller.isRunningSystemDiagnostics)

                        if controller.sysdiagnoseURL != nil {
                            Button("Reveal archive") {
                                controller.revealSystemDiagnostics()
                            }
                        }

                        Spacer()

                        Text("macOS global chord: ⌃⌥⇧⌘.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.42))
                    }
                }
            }
        }
    }

    private var spindumpCard: some View {
        diagnosticCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Spindump", systemImage: "waveform.path")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()

                    Button {
                        controller.generateSpindump()
                    } label: {
                        if controller.isGeneratingSpindump {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Generate Spindump", systemImage: "record.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isGeneratingSpindump || controller.isRunningSystemDiagnostics)

                    Button("Refresh") {
                        controller.reloadSpindumpPreview()
                    }
                    .disabled(controller.spindumpURL == nil || controller.isGeneratingSpindump)

                    Button("Save…") {
                        controller.saveSpindumpAs()
                    }
                    .disabled(controller.spindumpURL == nil)

                    Button("Reveal") {
                        controller.revealSpindump()
                    }
                    .disabled(controller.spindumpURL == nil)
                }

                Text("Samples user and kernel call stacks for 10 seconds. An administrator prompt is required.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.52))

                if let status = controller.statusMessage {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green.opacity(0.85))
                        .textSelection(.enabled)
                }

                if let error = controller.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                }

                ScrollView([.horizontal, .vertical]) {
                    Text(
                        controller.spindumpPreview.isEmpty
                            ? "Generate a spindump to preview the report here."
                            : controller.spindumpPreview
                    )
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.white.opacity(controller.spindumpPreview.isEmpty ? 0.35 : 0.78))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
                }
                .frame(minHeight: 330)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.3))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                )
            }
        }
    }

    private func diagnosticCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.raisedPanel)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
            )
    }
}

struct DiagnosticsCommands: Commands {
    var body: some Commands {
        CommandMenu("Diagnostics") {
            Button("Generate Spindump") {
                NotificationCenter.default.post(name: .showDiagnosticsTab, object: nil)
                DiagnosticsController.shared.generateSpindump()
            }

            Button("Run System Diagnostics") {
                NotificationCenter.default.post(name: .showDiagnosticsTab, object: nil)
                DiagnosticsController.shared.runSystemDiagnostics()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
