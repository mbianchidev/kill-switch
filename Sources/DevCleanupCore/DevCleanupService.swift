import Foundation
import TableQueryCore

public struct DevCleanupProcess: Equatable {
    public let pid: Int32
    public let user: String
    public let elapsedSeconds: Int
    public let command: String

    public init(pid: Int32, user: String, elapsedSeconds: Int, command: String) {
        self.pid = pid
        self.user = user
        self.elapsedSeconds = elapsedSeconds
        self.command = command
    }
}

public struct PortProcess: Identifiable, Equatable {
    public let id: String
    public let pid: Int32
    public let command: String
    public let port: Int

    public init(id: String, pid: Int32, command: String, port: Int) {
        self.id = id
        self.pid = pid
        self.command = command
        self.port = port
    }
}

public struct CleanedProcess: Identifiable, Equatable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let command: String
    public let runtime: String
    public let ageHours: Double

    public init(pid: Int32, command: String, runtime: String, ageHours: Double) {
        self.pid = pid
        self.command = command
        self.runtime = runtime
        self.ageHours = ageHours
    }
}

public struct DevCleanupConfiguration: Equatable {
    public let autoKillEnabled: Bool
    public let ageThresholdSeconds: Int
    public let effectivePorts: [Int]
    public let runtimes: [String]
    public let indicators: [String]
    public let exclusions: [String]

    public init(
        autoKillEnabled: Bool,
        ageThresholdSeconds: Int,
        effectivePorts: [Int],
        runtimes: [String],
        indicators: [String],
        exclusions: [String]
    ) {
        self.autoKillEnabled = autoKillEnabled
        self.ageThresholdSeconds = ageThresholdSeconds
        self.effectivePorts = effectivePorts
        self.runtimes = runtimes
        self.indicators = indicators
        self.exclusions = exclusions
    }
}

public enum DevPortTableFields {
    public static let port = TableField<PortProcess>.number("port", title: "Port", searchable: true) { Decimal($0.port) }
    public static let command = TableField<PortProcess>.text("command", title: "Command", aliases: ["name", "process"]) { $0.command }
    public static let pid = TableField<PortProcess>.number("pid", title: "PID", searchable: true) { Decimal($0.pid) }
    public static let protected = TableField<PortProcess>.boolean("protected", title: "Protected") {
        ProcessTerminationPolicy.protectionReason(for: $0.command) != nil
    }
    public static let columns = [port, command, pid]
    public static let all = columns + [protected]
}

public enum CleanedProcessTableFields {
    public static let runtime = TableField<CleanedProcess>.text("runtime", title: "Runtime") { $0.runtime }
    public static let age = TableField<CleanedProcess>.number("age", title: "Age", unit: .seconds) { $0.ageHours * 3_600 }
    public static let pid = TableField<CleanedProcess>.number("pid", title: "PID", searchable: true) { Decimal($0.pid) }
    public static let command = TableField<CleanedProcess>.text("command", title: "Command", aliases: ["name", "process"]) { $0.command }
    public static let all = [runtime, age, pid, command]
}

public struct DevCleanupScanResult: Equatable {
    public let portProcesses: [PortProcess]

    public init(portProcesses: [PortProcess]) {
        self.portProcesses = portProcesses
    }
}

public struct DevCleanupResult: Equatable {
    public let portProcesses: [PortProcess]
    public let candidateCount: Int
    public let killed: [CleanedProcess]

    public init(portProcesses: [PortProcess], candidateCount: Int, killed: [CleanedProcess]) {
        self.portProcesses = portProcesses
        self.candidateCount = candidateCount
        self.killed = killed
    }
}

public final class DevCleanupService {
    public typealias ProcessProvider = () throws -> [DevCleanupProcess]
    public typealias ListeningPortsProvider = () throws -> [Int32: Set<Int>]
    public typealias Terminator = (Int32) -> Bool

    private let username: String
    private let processProvider: ProcessProvider
    private let listeningPortsProvider: ListeningPortsProvider
    private let terminator: Terminator

    public init(
        username: String,
        processProvider: @escaping ProcessProvider,
        listeningPortsProvider: @escaping ListeningPortsProvider,
        terminator: @escaping Terminator
    ) {
        self.username = username
        self.processProvider = processProvider
        self.listeningPortsProvider = listeningPortsProvider
        self.terminator = terminator
    }

    public func scan(configuration: DevCleanupConfiguration) throws -> DevCleanupScanResult {
        let processes = try processProvider()
        let ports = try listeningPortsProvider()
        return DevCleanupScanResult(
            portProcesses: Self.portRows(
                processes: processes,
                ports: ports,
                notablePorts: Set(configuration.effectivePorts),
                runtimes: configuration.runtimes,
                indicators: configuration.indicators,
                exclusions: configuration.exclusions
            )
        )
    }

    public func cleanup(configuration: DevCleanupConfiguration) throws -> DevCleanupResult {
        let processes = try processProvider()
        let ports = try listeningPortsProvider()
        let portProcesses = Self.portRows(
            processes: processes,
            ports: ports,
            notablePorts: Set(configuration.effectivePorts),
            runtimes: configuration.runtimes,
            indicators: configuration.indicators,
            exclusions: configuration.exclusions
        )

        var candidateCount = 0
        var killed: [CleanedProcess] = []
        for process in processes where process.user == username {
            guard
                let runtime = Self.devRuntime(process.command, runtimes: configuration.runtimes),
                Self.isDevServer(process.command, indicators: configuration.indicators),
                !Self.isSystemProcess(process.command),
                !ProcessTerminationPolicy.isProtected(command: process.command),
                !Self.isExcluded(process.command, exclusions: configuration.exclusions)
            else {
                continue
            }

            candidateCount += 1
            if configuration.autoKillEnabled,
               process.elapsedSeconds > configuration.ageThresholdSeconds,
               terminator(process.pid) {
                killed.append(
                    CleanedProcess(
                        pid: process.pid,
                        command: process.command,
                        runtime: runtime,
                        ageHours: Double(process.elapsedSeconds) / 3600.0
                    )
                )
            }
        }

        return DevCleanupResult(
            portProcesses: portProcesses,
            candidateCount: candidateCount,
            killed: killed
        )
    }

    private static func portRows(
        processes: [DevCleanupProcess],
        ports: [Int32: Set<Int>],
        notablePorts: Set<Int>,
        runtimes: [String],
        indicators: [String],
        exclusions: [String]
    ) -> [PortProcess] {
        let commandByPID = Dictionary(
            processes.map { ($0.pid, $0.command) },
            uniquingKeysWith: { first, _ in first }
        )
        var rows: [PortProcess] = []
        for (pid, portSet) in ports {
            let command = commandByPID[pid] ?? "pid \(pid)"
            if isSystemProcess(command) { continue }
            let isDev = devRuntime(command, runtimes: runtimes) != nil
                && isDevServer(command, indicators: indicators)
                && !isExcluded(command, exclusions: exclusions)
            for port in portSet where notablePorts.contains(port) || isDev {
                rows.append(
                    PortProcess(id: "\(pid)-\(port)", pid: pid, command: command, port: port)
                )
            }
        }
        rows.sort { $0.port == $1.port ? $0.pid < $1.pid : $0.port < $1.port }
        return rows
    }

    private static func isExcluded(_ command: String, exclusions: [String]) -> Bool {
        let lower = command.lowercased()
        return exclusions.contains { lower.contains($0) }
    }

    private static func isSystemProcess(_ command: String) -> Bool {
        command.trimmingCharacters(in: .whitespaces).hasPrefix("/System/")
    }

    private static func isDevServer(_ command: String, indicators: [String]) -> Bool {
        let lower = command.lowercased()
        return indicators.contains { lower.contains($0) }
    }

    private static func devRuntime(_ command: String, runtimes: [String]) -> String? {
        guard let firstToken = command.split(whereSeparator: { $0.isWhitespace }).first else {
            return nil
        }
        let executable = firstToken.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        return runtimes.first { executable == $0 || executable.hasPrefix($0) }
    }
}
