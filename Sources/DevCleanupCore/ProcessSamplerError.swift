import Foundation

public enum ProcessSamplerError: LocalizedError, Equatable {
    case launchFailed(String, String)
    case commandFailed(String, Int32, String)

    public var cleanedStandardError: String? {
        guard case .commandFailed(_, _, let standardError) = self else { return nil }
        let message = standardError
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return message.isEmpty ? nil : message
    }

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let path, let message):
            return "Could not launch \(path): \(message)"
        case .commandFailed(let path, let status, _):
            guard let message = cleanedStandardError else {
                return "\(path) exited with status \(status)."
            }
            return "\(path) exited with status \(status): \(message)"
        }
    }
}
