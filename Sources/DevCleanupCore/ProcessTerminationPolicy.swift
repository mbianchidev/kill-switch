import Foundation

public enum ProcessTerminationPolicy {
    private static let portoProtectionReason =
        "Porto-managed Lima hostagents control their own lifecycle."

    public static func isProtected(command: String) -> Bool {
        protectionReason(for: command) != nil
    }

    public static func protectionReason(for command: String) -> String? {
        let tokens = command
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
        let isLimaHostAgent = tokens.indices.dropLast().contains { index in
            let executable = tokens[index].split(separator: "/").last
            return executable == "limactl" && tokens[tokens.index(after: index)] == "hostagent"
        }
        guard
            isLimaHostAgent,
            tokens.contains(where: isPortoIdentifier)
        else {
            return nil
        }
        return portoProtectionReason
    }

    private static func isPortoIdentifier(_ token: Substring) -> Bool {
        token.hasPrefix("porto-") || token.contains("/porto-")
    }
}
