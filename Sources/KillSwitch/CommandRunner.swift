import Foundation

struct CommandResult {
    let status: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { status == 0 }
}

enum CommandRunnerError: LocalizedError {
    case launchFailed(executable: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(executable, underlying):
            return "Could not launch \(executable): \(underlying.localizedDescription)"
        }
    }
}

enum CommandRunner {
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

    static func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
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
            standardOutput: String(data: outputBox.load(), encoding: .utf8) ?? "",
            standardError: String(data: errorBox.load(), encoding: .utf8) ?? ""
        )
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
