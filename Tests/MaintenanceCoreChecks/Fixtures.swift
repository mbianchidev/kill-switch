import Foundation
import MaintenanceCore
import SoftwareInventoryCore

/// Answers mocked commands and passes everything else (git, zipinfo, tar) to the real runner.
final class ScriptedRunner: SoftwareCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SoftwareCommand] = []
    var handler: (SoftwareCommand) -> SoftwareCommandResult?

    init(_ handler: @escaping (SoftwareCommand) -> SoftwareCommandResult? = { _ in nil }) {
        self.handler = handler
    }

    var commands: [SoftwareCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ command: SoftwareCommand) throws -> SoftwareCommandResult {
        lock.lock()
        recorded.append(command)
        lock.unlock()
        if let answer = handler(command) { return answer }
        return try NativeSoftwareCommandRunner().run(command)
    }

    static func ok(_ output: String = "") -> SoftwareCommandResult { SoftwareCommandResult(status: 0, output: output, error: "") }
    static func failed(_ error: String, status: Int32 = 1) -> SoftwareCommandResult { SoftwareCommandResult(status: status, output: "", error: error) }
}

enum Fixture {
    static let idleLsof = "p1\ncsynthetic-shell\nfcwd\nn/\n"

    static func lsof(cwd: [String] = [], open: [(String, String)] = []) -> String {
        var lines = [idleLsof]
        for (index, path) in cwd.enumerated() { lines.append("p\(90_000 + index)\ncsynthetic-tool\nfcwd\nn\(path)\n") }
        for (index, entry) in open.enumerated() { lines.append("p\(91_000 + index)\nc\(entry.1)\nf5r\nn\(entry.0)\n") }
        return lines.joined()
    }

    static func hdiutilInfo(_ images: [(path: String, owner: UInt32, writeable: Bool, device: String, mount: String?)]) -> String {
        let plist: [String: Any] = ["images": images.map { image in
            [
                "image-path": image.path, "owner-uid": NSNumber(value: image.owner), "writeable": image.writeable,
                "system-entities": [["dev-entry": image.device], ["dev-entry": image.device + "s1", "mount-point": image.mount ?? ""]]
                    .map { entry in entry.filter { !($0.value as? String ?? "x").isEmpty } }
            ] as [String: Any]
        }]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }

    static func pullRequests(_ entries: [(number: Int, state: String, merged: String?, sha: String, ref: String)]) -> String {
        let objects = entries.map { entry -> String in
            let merged = entry.merged.map { "\"\($0)\"" } ?? "null"
            return #"{"number": \#(entry.number), "state": "\#(entry.state)", "merged_at": \#(merged), "head": {"sha": "\#(entry.sha)", "ref": "\#(entry.ref)"}, "html_url": "https://github.com/synthetic-owner/demo/pull/\#(entry.number)"}"#
        }
        return "[" + objects.joined(separator: ",") + "]"
    }
}

/// A synthetic home folder with a main checkout and linked agent worktrees.
struct SyntheticHome {
    let home: URL
    let fileManager = FileManager.default

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MaintenanceCoreChecks-\(UUID().uuidString)")
        home = URL(fileURLWithPath: MaintenancePath.resolved(base.path))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for folder in ["Downloads", "Desktop", "Library", ".copilot/session-state", "workspace/copilot-worktrees", "src"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }

    func remove() { try? fileManager.removeItem(at: home) }

    @discardableResult
    func git(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "init.defaultBranch=main"] + arguments
        process.environment = [
            "GIT_AUTHOR_NAME": "Synthetic", "GIT_AUTHOR_EMAIL": "synthetic@example.com",
            "GIT_COMMITTER_NAME": "Synthetic", "GIT_COMMITTER_EMAIL": "synthetic@example.com",
            "GIT_CONFIG_NOSYSTEM": "1", "HOME": home.path, "PATH": "/usr/bin:/bin"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SyntheticGit", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ relative: String, _ text: String = "synthetic", modified: Date? = nil) throws {
        let url = home.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    func makeApp(_ relative: String, identifier: String, version: String, build: String = "1") throws {
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                    "CFBundleVersion": build, "CFBundleName": (relative as NSString).lastPathComponent]
        let url = home.appendingPathComponent(relative).appendingPathComponent("Contents/Info.plist")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    /// `src/demo` with an origin on github.com and linked worktrees under the Copilot worktree root.
    func makeRepository() throws -> String {
        let main = path("src/demo")
        try fileManager.createDirectory(atPath: main, withIntermediateDirectories: true)
        try git(["init", "-q"], in: main)
        try write("src/demo/.gitignore", "node_modules/\ndist/\ntarget/\nbuild/\ncoverage/\n*.dmg\n*.zip\n.env\n")
        try write("src/demo/Cargo.toml", "[package]\nname = \"demo\"\n")
        try write("src/demo/README.md", "Synthetic repository\n")
        try git(["add", "."], in: main)
        try git(["commit", "-q", "-m", "Synthetic initial commit"], in: main)
        try git(["remote", "add", "origin", "git@github.com:synthetic-owner/demo.git"], in: main)
        return main
    }

    func addWorktree(_ name: String, branch: String, main: String) throws -> String {
        let worktree = path("workspace/copilot-worktrees/demo/\(name)")
        try git(["worktree", "add", "-q", "-b", branch, worktree], in: main)
        return worktree
    }
}
