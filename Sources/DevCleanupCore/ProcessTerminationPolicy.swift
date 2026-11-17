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

    /// Reads `pid`'s command line, refuses uninspectable or protected processes, then sends SIGTERM,
    /// falling back to SIGKILL if sending fails. `shouldContinue` is rechecked after the read,
    /// immediately before each signal, so permission revoked during a slow read stops the kill.
    public static func terminate(
        pid: Int32,
        commandLine: (Int32) -> String?,
        shouldContinue: () -> Bool = { true },
        signal: (Int32, Int32) -> Int32,
        report: (String) -> Void = { fputs("\($0)\n", stderr) }
    ) -> Bool {
        guard let command = commandLine(pid) else {
            report("KillSwitch refused to terminate PID \(pid): its command line could not be inspected.")
            return false
        }
        if let reason = protectionReason(for: command) {
            report("KillSwitch refused to terminate PID \(pid): \(reason)")
            return false
        }
        guard shouldContinue() else {
            report("KillSwitch did not terminate PID \(pid): permission was revoked during inspection.")
            return false
        }
        if signal(pid, SIGTERM) == 0 { return true }
        guard shouldContinue() else { return false }
        return signal(pid, SIGKILL) == 0
    }
}
