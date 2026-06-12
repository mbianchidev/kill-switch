import Foundation
import AppKit

/// Shared helpers for sampling running processes via `ps` / `lsof`.
///
/// Both the collapsed (parent-aggregated) view used by the main process list /
/// top consumers and the detailed (per-process, full command line) view used by
/// the dev cleanup live here so the parsing logic isn't duplicated.
enum ProcessSampler {

    // MARK: - Detailed sampling (per process, full command line)

    /// A single process as reported by `ps`, keeping the full command line so
    /// callers can classify it (dev server detection, exclusion lists, ...).
    struct Detailed {
        let pid: Int32
        let ppid: Int32
        let user: String
        let etimeSeconds: Int
        let command: String
    }

    /// Parse a `ps` ELAPSED time (`[[dd-]hh:]mm:ss`) into seconds.
    static func parseEtime(_ raw: String) -> Int {
        var days = 0
        var rest = Substring(raw)
        if let dash = raw.firstIndex(of: "-") {
            days = Int(raw[raw.startIndex..<dash]) ?? 0
            rest = raw[raw.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Int($0) ?? 0 }
        var hours = 0, minutes = 0, seconds = 0
        switch parts.count {
        case 3: hours = parts[0]; minutes = parts[1]; seconds = parts[2]
        case 2: minutes = parts[0]; seconds = parts[1]
        case 1: seconds = parts[0]
        default: break
        }
        return ((days * 24 + hours) * 60 + minutes) * 60 + seconds
    }

    /// Fetch every process with its owner, elapsed time and full command line.
    static func fetchDetailed() -> [Detailed] {
        guard let output = runProcess("/bin/ps", ["-axo", "pid,ppid,user,etime,args"]) else {
            return []
        }
        var result: [Detailed] = []
        for line in output.components(separatedBy: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Keep the command line (which contains spaces) intact as the last field.
            let parts = trimmed.split(maxSplits: 4, omittingEmptySubsequences: true) { $0.isWhitespace }
            guard parts.count >= 5,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            result.append(
                Detailed(
                    pid: pid,
                    ppid: ppid,
                    user: String(parts[2]),
                    etimeSeconds: parseEtime(String(parts[3])),
                    command: String(parts[4])
                )
            )
        }
        return result
    }

    // MARK: - Listening ports

    /// Map of pid -> set of TCP ports the process is listening on.
    static func listeningPorts() -> [Int32: Set<Int>] {
        guard let output = runProcess("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"]) else {
            return [:]
        }
        var map: [Int32: Set<Int>] = [:]
        for line in output.components(separatedBy: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2, let pid = Int32(parts[1]) else { continue }
            // Find the address token (e.g. "*:3000", "127.0.0.1:8080", "[::1]:9000").
            for token in parts where token.contains(":") {
                if let portStr = token.split(separator: ":").last, let port = Int(portStr) {
                    map[pid, default: []].insert(port)
                }
            }
        }
        return map
    }

    // MARK: - Collapsed sampling (parent-aggregated, with icons)

    private struct Raw {
        let pid: Int32
        let ppid: Int32
        let cpu: Double
        let memory: Double
        let name: String
    }

    /// Fetch processes for `user`, collapsing helper/child processes into their
    /// top-most ancestor and aggregating CPU and memory into that parent.
    static func fetchCollapsed(user: String) -> [ProcessEntry] {
        guard let output = runProcess("/bin/ps", ["-u", user, "-o", "pid,ppid,pcpu,rss,comm", "-r"]) else {
            return []
        }
        var raw: [Int32: Raw] = [:]
        for line in output.components(separatedBy: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(maxSplits: 4, omittingEmptySubsequences: true) { $0.isWhitespace }
            guard parts.count >= 5,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let cpu = Double(parts[2]),
                  let rssKB = Double(parts[3]) else { continue }
            let name = String(parts[4]).components(separatedBy: "/").last ?? String(parts[4])
            raw[pid] = Raw(pid: pid, ppid: ppid, cpu: cpu, memory: rssKB / 1024.0, name: name)
        }
        return collapse(raw)
    }

    private static func collapse(_ raw: [Int32: Raw]) -> [ProcessEntry] {
        let icons = appIcons()

        func rootPid(of pid: Int32) -> Int32 {
            var current = pid
            var visited: Set<Int32> = []
            while let proc = raw[current], raw[proc.ppid] != nil {
                if visited.contains(current) { break }
                visited.insert(current)
                current = proc.ppid
            }
            return current
        }

        var aggregatedCPU: [Int32: Double] = [:]
        var aggregatedMemory: [Int32: Double] = [:]
        for (pid, proc) in raw {
            let root = rootPid(of: pid)
            aggregatedCPU[root, default: 0] += proc.cpu
            aggregatedMemory[root, default: 0] += proc.memory
        }

        var entries: [ProcessEntry] = []
        for root in aggregatedCPU.keys {
            guard let proc = raw[root] else { continue }
            entries.append(
                ProcessEntry(
                    pid: root,
                    name: proc.name,
                    cpu: aggregatedCPU[root] ?? proc.cpu,
                    memory: aggregatedMemory[root] ?? proc.memory,
                    icon: icons[root]
                )
            )
        }
        return entries
    }

    private static func appIcons() -> [Int32: NSImage] {
        var map: [Int32: NSImage] = [:]
        for app in NSWorkspace.shared.runningApplications where app.icon != nil {
            map[app.processIdentifier] = app.icon
        }
        return map
    }

    // MARK: - Process termination

    /// Terminate a process with SIGTERM, falling back to SIGKILL.
    @discardableResult
    static func terminate(pid: Int32) -> Bool {
        if kill(pid, SIGTERM) == 0 { return true }
        return kill(pid, SIGKILL) == 0
    }

    // MARK: - Helpers

    private static func runProcess(_ launchPath: String, _ arguments: [String]) -> String? {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
