#!/usr/bin/env swift
import Darwin
import Foundation

struct FootprintReading: Codable {
    let elapsed: Double
    let cpuSeconds: Double
    let residentBytes: UInt64
    let footprintBytes: UInt64
}

struct FootprintRun: Codable {
    let scenario: String
    let repetition: Int
    let duration: Double
    let appCPUSeconds: Double
    let appAverageCPUPercent: Double
    let appP95CPUPercent: Double
    let steadyResidentBytes: UInt64
    let peakResidentBytes: UInt64
    let steadyFootprintBytes: UInt64
    let peakFootprintBytes: UInt64
    let waitedCPUSecondsIncludingChildren: Double
    let readings: [FootprintReading]
}

struct FootprintReport: Codable {
    let schemaVersion: Int
    let revision: String
    let operatingSystem: String
    let hardwareModel: String
    let architecture: String
    let logicalCPUs: Int
    let configuration: String
    let processCount: Int
    let warmupSeconds: Double
    let samplingSeconds: Double
    let cpuNormalization: String
    let coverage: String
    let runs: [FootprintRun]
}

enum MeasurementError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

func failure(_ message: String) -> MeasurementError {
    .message("\(message): \(String(cString: strerror(errno)))")
}

func processReading(pid: Int32, start: Date) throws -> FootprintReading {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard status == 0 else { throw failure("Cannot read benchmark process \(pid)") }
    return FootprintReading(
        elapsed: Date().timeIntervalSince(start),
        cpuSeconds: Double(info.ri_user_time + info.ri_system_time) / 1_000_000_000,
        residentBytes: info.ri_resident_size, footprintBytes: info.ri_phys_footprint
    )
}

func median(_ values: [UInt64]) -> UInt64 {
    values.sorted()[values.count / 2]
}

func measure(
    executable: String, scenario: String, repetition: Int, duration: Double, count: Int, directory: URL
) throws -> FootprintRun {
    let log = directory.appendingPathComponent("\(scenario)-\(repetition).log")
    let descriptor = Darwin.open(log.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw failure("Cannot create benchmark log") }
    defer { Darwin.close(descriptor) }
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw failure("Cannot initialize benchmark launch") }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawn_file_actions_adddup2(&actions, descriptor, STDOUT_FILENO) == 0,
          posix_spawn_file_actions_adddup2(&actions, descriptor, STDERR_FILENO) == 0,
          posix_spawn_file_actions_addclose(&actions, descriptor) == 0 else {
        throw MeasurementError.message("Cannot configure benchmark output")
    }
    let strings = [executable, scenario, String(duration), String(count)]
    var argv = strings.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    guard argv.dropLast().allSatisfy({ $0 != nil }) else { throw MeasurementError.message("Cannot allocate benchmark arguments") }
    var pid: pid_t = 0
    let spawn = posix_spawn(&pid, executable, &actions, nil, &argv, environ)
    guard spawn == 0 else {
        throw MeasurementError.message("Cannot launch benchmark: \(String(cString: strerror(spawn)))")
    }
    var reaped = false
    defer {
        if !reaped {
            Darwin.kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }
    let start = Date()
    var readings: [FootprintReading] = []
    var usage = rusage()
    var status: Int32 = 0
    while true {
        let waited = wait4(pid, &status, WNOHANG, &usage)
        if waited == pid { reaped = true; break }
        guard waited >= 0 else { throw failure("Cannot wait for benchmark") }
        guard Date().timeIntervalSince(start) <= duration + 30 else {
            throw MeasurementError.message("Benchmark exceeded its deadline")
        }
        do { readings.append(try processReading(pid: pid, start: start)) }
        catch {
            if errno != ESRCH { throw error }
        }
        usleep(100_000)
    }
    guard status == 0 else {
        let detail = try String(contentsOf: log, encoding: .utf8)
        throw MeasurementError.message("Benchmark \(scenario) failed (wait status \(status)): \(detail)")
    }
    let steady = readings.filter { $0.elapsed >= 2 }
    guard let first = steady.first, let last = steady.last, steady.count >= 2 else {
        throw MeasurementError.message("Benchmark did not expose enough steady-state readings")
    }
    let cpuRates = zip(steady, steady.dropFirst()).map { previous, current in
        100 * (current.cpuSeconds - previous.cpuSeconds) / (current.elapsed - previous.elapsed)
    }.sorted()
    guard cpuRates.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
        throw MeasurementError.message("Benchmark returned invalid CPU counters")
    }
    let tail = steady.suffix(max(1, steady.count / 3))
    let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    return FootprintRun(
        scenario: scenario, repetition: repetition, duration: last.elapsed - first.elapsed,
        appCPUSeconds: last.cpuSeconds,
        appAverageCPUPercent: 100 * (last.cpuSeconds - first.cpuSeconds) / (last.elapsed - first.elapsed),
        appP95CPUPercent: cpuRates[min(cpuRates.count - 1, Int(Double(cpuRates.count) * 0.95))],
        steadyResidentBytes: median(tail.map(\.residentBytes)),
        peakResidentBytes: max(UInt64(usage.ru_maxrss), readings.map(\.residentBytes).max() ?? 0),
        steadyFootprintBytes: median(tail.map(\.footprintBytes)),
        peakFootprintBytes: readings.map(\.footprintBytes).max() ?? 0,
        waitedCPUSecondsIncludingChildren: cpu, readings: readings
    )
}

func hardwareModel() throws -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
        throw failure("Cannot identify benchmark hardware class")
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
        throw failure("Cannot read benchmark hardware class")
    }
    return String(cString: bytes)
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 6, let duration = Double(arguments[2]), (3...600).contains(duration),
          let repetitions = Int(arguments[3]), (1...10).contains(repetitions),
          let count = Int(arguments[4]), (1...5_000).contains(count) else {
        throw MeasurementError.message("Usage: swift scripts/measure-footprint.swift PROBE REPORT.json SECONDS REPETITIONS PROCESSES REVISION")
    }
    let executable = URL(fileURLWithPath: arguments[0]).standardizedFileURL.path
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        throw MeasurementError.message("Build the isolated release probe before measuring")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("killswitch-footprint-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    var cleanupError: Error?
    var runs: [FootprintRun] = []
    do {
        for scenario in ["background", "dashboard", "cpu", "memory", "energy"] {
            for repetition in 1...repetitions {
                let run = try measure(
                    executable: executable, scenario: scenario, repetition: repetition,
                    duration: duration, count: count, directory: directory
                )
                runs.append(run)
                print(String(
                    format: "%@ #%d: %.2f%% CPU, %.1f MiB steady footprint, %.1f MiB peak RSS",
                    scenario, repetition, run.appAverageCPUPercent,
                    Double(run.steadyFootprintBytes) / 1_048_576, Double(run.peakResidentBytes) / 1_048_576
                ))
            }
        }
    } catch {
        do { try FileManager.default.removeItem(at: directory) }
        catch { fputs("Benchmark cleanup failed: \(error.localizedDescription)\n", stderr) }
        throw error
    }
    do { try FileManager.default.removeItem(at: directory) }
    catch { cleanupError = error }
    if let cleanupError { throw cleanupError }
#if arch(arm64)
    let architecture = "arm64"
#else
    let architecture = "x86_64"
#endif
    let report = FootprintReport(
        schemaVersion: 1, revision: arguments[5], operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        hardwareModel: try hardwareModel(), architecture: architecture, logicalCPUs: ProcessInfo.processInfo.processorCount,
        configuration: "Swift release (-O), KILLSWITCH_PERFORMANCE_PROBE", processCount: count,
        warmupSeconds: 2, samplingSeconds: 0.1, cpuNormalization: "100% equals one logical CPU core; not divided by CPU count",
        coverage: "Synthetic 51-sample history and process rows. Dashboard includes the app shell; resource pages render directly. Offscreen AppKit drawing, no desktop interaction, live collectors, real history, or cleanup. Peak physical footprint is observed at 100 ms, not the lifetime kernel peak. wait4 CPU includes waited children; these synthetic scenarios launch none.",
        runs: runs
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
} catch {
    fputs("Footprint measurement failed: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
