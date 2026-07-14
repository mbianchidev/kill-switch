import Foundation

public enum ProcessSamplerError: LocalizedError, Equatable {
    case launchFailed(String, String)
    case commandFailed(String, Int32, String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let path, let message):
            return "Could not launch \(path): \(message)"
        case .commandFailed(let path, let status, let standardError):
            let message = standardError
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if message.isEmpty {
                return "\(path) exited with status \(status)."
            }
            return "\(path) exited with status \(status): \(message)"
        }
    }
}
