import Foundation

public struct ParsedCPUSummary {
    public let userPercent: Double
    public let systemPercent: Double
    public let idlePercent: Double
    public let processCount: Int
    public let runningCount: Int
    public let threadCount: Int
}

public struct ParsedTopProcess {
    public let pid: Int32
    public let cpu: Double
    public let cpuTimeSeconds: Double
    public let threads: Int
    public let idleWakeUps: UInt64?
    public let power: Double
    public let memoryBytes: UInt64
    public let ports: Int
    public let user: String
    public let command: String
}

public struct ParsedTopSnapshot {
    public let processes: [ParsedTopProcess]
    public let cpu: ParsedCPUSummary
}

public struct ParsedPSProcess {
    public let pid: Int32
    public let user: String
    public let isRunning: Bool
    public let cpu: Double
    public let cpuTimeSeconds: Double
    public let memoryBytes: UInt64
    public let command: String
}

public struct ParsedNetworkProcess {
    public let receivedPackets: UInt64
    public let receivedBytes: UInt64
    public let sentPackets: UInt64
    public let sentBytes: UInt64

    public static let zero = ParsedNetworkProcess(
        receivedPackets: 0,
        receivedBytes: 0,
        sentPackets: 0,
        sentBytes: 0
    )
}

public struct ParsedNetworkTotals {
    public let receivedPackets: UInt64
    public let receivedBytes: UInt64
    public let sentPackets: UInt64
    public let sentBytes: UInt64
}

public struct ParsedBatterySummary {
    public let source: String
    public let chargePercent: Int?
    public let status: String
    public let timeRemaining: String?
}

public enum SystemMetricsParserError: LocalizedError {
    case missingTopSnapshot

    public var errorDescription: String? {
        switch self {
        case .missingTopSnapshot:
            return "The system process snapshot did not contain a complete sample."
        }
    }
}

public enum SystemMetricsParser {
    public static func parseTop(_ output: String) throws -> ParsedTopSnapshot {
        let lines = output.components(separatedBy: .newlines)
        guard
            let processSummaryIndex = lines.lastIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("Processes:")
            }),
            let headerIndex = lines[processSummaryIndex...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("PID")
            })
        else {
            throw SystemMetricsParserError.missingTopSnapshot
        }

        let summaryLines = lines[processSummaryIndex..<headerIndex]
        var totalProcesses = 0
        var runningProcesses = 0
        var totalThreads = 0
        var userCPU = 0.0
        var systemCPU = 0.0
        var idleCPU = 0.0

        for line in summaryLines {
            if let values = captures(
                pattern: #"Processes:\s+(\d+)\s+total,\s+(\d+)\s+running,.*?(\d+)\s+threads"#,
                in: line
            ) {
                totalProcesses = Int(values[0]) ?? 0
                runningProcesses = Int(values[1]) ?? 0
                totalThreads = Int(values[2]) ?? 0
            } else if let values = captures(
                pattern: #"CPU usage:\s+([\d.]+)% user,\s+([\d.]+)% sys,\s+([\d.]+)% idle"#,
                in: line
            ) {
                userCPU = Double(values[0]) ?? 0
                systemCPU = Double(values[1]) ?? 0
                idleCPU = Double(values[2]) ?? 0
            }
        }

        var processes: [ParsedTopProcess] = []
        if headerIndex + 1 < lines.count {
            for line in lines[(headerIndex + 1)...] {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let fields = trimmed.split(
                    maxSplits: 9,
                    omittingEmptySubsequences: true,
                    whereSeparator: { $0.isWhitespace }
                ).map(String.init)
                guard fields.count == 10, let pid = Int32(fields[0]) else { continue }

                processes.append(
                    ParsedTopProcess(
                        pid: pid,
                        cpu: parseDouble(fields[1]) ?? 0,
                        cpuTimeSeconds: parseCPUTime(fields[2]) ?? 0,
                        threads: parseLeadingInt(fields[3]) ?? 0,
                        idleWakeUps: parseUnsigned(fields[4]),
                        power: parseDouble(fields[5]) ?? 0,
                        memoryBytes: parseByteCount(fields[6]) ?? 0,
                        ports: parseLeadingInt(fields[7]) ?? 0,
                        user: fields[8],
                        command: fields[9].trimmingCharacters(in: .whitespaces)
                    )
                )
            }
        }

        return ParsedTopSnapshot(
            processes: processes,
            cpu: ParsedCPUSummary(
                userPercent: userCPU,
                systemPercent: systemCPU,
                idlePercent: idleCPU,
                processCount: totalProcesses,
                runningCount: runningProcesses,
                threadCount: totalThreads
            )
        )
    }

    public static func parseNetworkProcesses(_ output: String) -> [Int32: ParsedNetworkProcess] {
        var result: [Int32: ParsedNetworkProcess] = [:]

        for line in output.components(separatedBy: .newlines).dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard fields.count >= 5, let separator = fields[0].lastIndex(of: ".") else { continue }

            let pidText = fields[0][fields[0].index(after: separator)...]
            guard let pid = Int32(pidText) else { continue }

            result[pid] = ParsedNetworkProcess(
                receivedPackets: UInt64(fields[1]) ?? 0,
                receivedBytes: UInt64(fields[2]) ?? 0,
                sentPackets: UInt64(fields[3]) ?? 0,
                sentBytes: UInt64(fields[4]) ?? 0
            )
        }

        return result
    }

    public static func parsePSProcesses(_ output: String) -> [ParsedPSProcess] {
        var result: [ParsedPSProcess] = []

        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(
                maxSplits: 6,
                omittingEmptySubsequences: true,
                whereSeparator: { $0.isWhitespace }
            ).map(String.init)
            guard
                fields.count == 7,
                let pid = Int32(fields[0]),
                let cpu = parseDouble(fields[3]),
                let cpuTime = parseCPUTime(fields[4]),
                let residentKB = UInt64(fields[5])
            else {
                continue
            }

            result.append(
                ParsedPSProcess(
                    pid: pid,
                    user: fields[1],
                    isRunning: fields[2].first == "R",
                    cpu: cpu,
                    cpuTimeSeconds: cpuTime,
                    memoryBytes: residentKB * 1_024,
                    command: fields[6]
                )
            )
        }

        return result
    }

    public static func parseNetworkTotals(_ output: String) -> ParsedNetworkTotals? {
        var seenInterfaces: Set<String> = []
        var receivedPackets: UInt64 = 0
        var receivedBytes: UInt64 = 0
        var sentPackets: UInt64 = 0
        var sentBytes: UInt64 = 0

        for line in output.components(separatedBy: .newlines) where line.contains("<Link#") {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 10 else { continue }

            let name = fields[0].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard seenInterfaces.insert(name).inserted else { continue }

            let counters = fields.suffix(7)
            receivedPackets += UInt64(counters[counters.startIndex]) ?? 0
            receivedBytes += UInt64(counters[counters.index(counters.startIndex, offsetBy: 2)]) ?? 0
            sentPackets += UInt64(counters[counters.index(counters.startIndex, offsetBy: 3)]) ?? 0
            sentBytes += UInt64(counters[counters.index(counters.startIndex, offsetBy: 5)]) ?? 0
        }

        guard !seenInterfaces.isEmpty else { return nil }
        return ParsedNetworkTotals(
            receivedPackets: receivedPackets,
            receivedBytes: receivedBytes,
            sentPackets: sentPackets,
            sentBytes: sentBytes
        )
    }

    public static func parseMemoryPressureFreePercentage(_ output: String) -> Double? {
        guard let values = captures(pattern: #"free percentage:\s+([\d.]+)%"#, in: output) else {
            return nil
        }
        return Double(values[0])
    }

    public static func parseBattery(_ output: String) -> ParsedBatterySummary {
        let source = captures(pattern: #"Now drawing from '([^']+)'"#, in: output)?.first ?? "Unknown"
        guard
            let detailLine = output.components(separatedBy: .newlines).first(where: { $0.contains("%;") }),
            let values = captures(pattern: #"(\d+)%;\s*([^;]+);\s*([^;]+)"#, in: detailLine)
        else {
            return ParsedBatterySummary(
                source: source,
                chargePercent: nil,
                status: source == "AC Power" ? "No battery details" : "Unavailable",
                timeRemaining: nil
            )
        }

        let status = values[1].trimmingCharacters(in: .whitespaces)
        let time = values[2]
            .components(separatedBy: " present:")
            .first?
            .trimmingCharacters(in: .whitespaces)
        return ParsedBatterySummary(
            source: source,
            chargePercent: Int(values[0]),
            status: status,
            timeRemaining: time == "0:00 remaining" ? nil : time
        )
    }

    public static func parsePreventingSleepPIDs(_ output: String) -> Set<Int32> {
        var result: Set<Int32> = []
        let pattern = #"pid\s+(\d+)\([^)]*\):.*\bPrevent[A-Za-z]*Sleep\b"#
        for line in output.components(separatedBy: .newlines) {
            guard let value = captures(pattern: pattern, in: line)?.first, let pid = Int32(value) else {
                continue
            }
            result.insert(pid)
        }
        return result
    }

    public static func parseByteCount(_ raw: String) -> UInt64? {
        var trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
        if trimmed.last == "+" || trimmed.last == "-" {
            trimmed.removeLast()
        }

        let pattern = #"^([\d.]+)\s*([KMGT]?)(?:I?B)?$"#
        guard let values = captures(pattern: pattern, in: trimmed.uppercased()),
              let number = Double(values[0]) else {
            return nil
        }

        let multiplier: Double
        switch values[1] {
        case "K": multiplier = 1_024
        case "M": multiplier = 1_048_576
        case "G": multiplier = 1_073_741_824
        case "T": multiplier = 1_099_511_627_776
        default: multiplier = 1
        }

        return UInt64(max(0, number * multiplier))
    }

    public static func parseCPUTime(_ raw: String) -> Double? {
        var daySeconds = 0.0
        var timeText = raw
        if let separator = raw.firstIndex(of: "-") {
            daySeconds = (Double(raw[..<separator]) ?? 0) * 86_400
            timeText = String(raw[raw.index(after: separator)...])
        }

        let parts = timeText.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 1:
            return daySeconds + parts[0]
        case 2:
            return daySeconds + parts[0] * 60 + parts[1]
        case 3:
            return daySeconds + parts[0] * 3_600 + parts[1] * 60 + parts[2]
        default:
            return nil
        }
    }

    private static func parseDouble(_ raw: String) -> Double? {
        Double(raw.trimmingCharacters(in: CharacterSet(charactersIn: "+")))
    }

    private static func parseLeadingInt(_ raw: String) -> Int? {
        guard let first = raw.split(separator: "/").first else { return nil }
        var cleaned = String(first)
        if cleaned.last == "+" || cleaned.last == "-" {
            cleaned.removeLast()
        }
        guard let value = Int(cleaned), value >= 0 else { return nil }
        return value
    }

    private static func parseUnsigned(_ raw: String) -> UInt64? {
        var cleaned = raw
        if cleaned.last == "+" || cleaned.last == "-" {
            cleaned.removeLast()
        }
        return UInt64(cleaned)
    }

    private static func captures(pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }

        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }
}
