import Foundation

public struct CommandResult {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { status == 0 }
}

public enum CommandRunnerError: LocalizedError {
    case launchFailed(executable: String, underlying: Error)
    case commandFailed(executable: String, status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(executable, underlying):
            return "Could not launch \(executable): \(underlying.localizedDescription)"
        case let .commandFailed(executable, status, message):
            return "\(executable) exited with status \(status): \(message)"
        }
    }
}

public enum CommandOutputDecoding: Sendable {
    /// Byte-exact UTF-8. Invalid output decodes as empty, so callers that write text back never act on altered bytes.
    case strictUTF8
    /// Replaces invalid bytes with U+FFFD. Use only for output that is parsed and never written back.
    case lossyUTF8

    func decode(_ data: Data) -> String {
        switch self {
        case .strictUTF8: return String(data: data, encoding: .utf8) ?? ""
        case .lossyUTF8: return String(decoding: data, as: UTF8.self)
        }
    }
}

public enum CommandRunner {
    private final class DataBox {
        private let lock = NSLock()
        private var data = Data()

        func store(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
        }

        func load() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    public static func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        outputDecoding: CommandOutputDecoding = .strictUTF8
    ) throws -> CommandResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        if !environment.isEmpty {
            task.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in
                replacement
            }
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
        } catch {
            throw CommandRunnerError.launchFailed(executable: executable, underlying: error)
        }

        let outputBox = DataBox()
        let errorBox = DataBox()
        let readers = DispatchGroup()

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.store(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.store(errorPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        task.waitUntilExit()
        readers.wait()

        return CommandResult(
            status: task.terminationStatus,
            standardOutput: outputDecoding.decode(outputBox.load()),
            standardError: outputDecoding.decode(errorBox.load())
        )
    }

    @discardableResult
    public static func runChecked(
        _ executable: String,
        arguments: [String] = []
    ) throws -> CommandResult {
        let result = try run(executable, arguments: arguments)
        guard result.succeeded else {
            throw CommandRunnerError.commandFailed(
                executable: executable,
                status: result.status,
                message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
