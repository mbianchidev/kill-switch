import Foundation
import InstallCore

public struct SoftwareCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    public init(_ executable: String, arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    public var displayString: String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
    }
}

public struct SoftwareCommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String
    public let error: String

    public init(status: Int32, output: String, error: String) {
        self.status = status
        self.output = output
        self.error = error
    }

    public var succeeded: Bool { status == 0 }
}

public protocol SoftwareCommandRunning: Sendable {
    func run(_ command: SoftwareCommand) throws -> SoftwareCommandResult
}

public struct NativeSoftwareCommandRunner: SoftwareCommandRunning {
    public init() {}

    public func run(_ command: SoftwareCommand) throws -> SoftwareCommandResult {
        // Output is parsed or displayed, never written back, so invalid bytes may be replaced.
        let result = try CommandRunner.run(
            command.executable, arguments: command.arguments,
            environment: command.environment, outputDecoding: .lossyUTF8
        )
        return SoftwareCommandResult(status: result.status, output: result.standardOutput, error: result.standardError)
    }
}

public enum SoftwareCommandError: LocalizedError, Equatable, Sendable {
    case failed(command: String, status: Int32, message: String)
    case unreadableOutput(command: String, message: String)

    public var errorDescription: String? {
        switch self {
        case let .failed(command, status, message):
            let detail = message.isEmpty ? "no error output" : message
            return "\(command) exited with status \(status): \(detail)"
        case let .unreadableOutput(command, message):
            return "Could not read the output of \(command): \(message)"
        }
    }
}

extension SoftwareCommandRunning {
    /// Runs a command that must succeed and returns its standard output.
    func checkedOutput(_ command: SoftwareCommand) throws -> String {
        let result = try run(command)
        guard result.succeeded else {
            throw SoftwareCommandError.failed(
                command: command.displayString, status: result.status,
                message: result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.output
    }
}
