import Foundation

public enum StartupParsers {
    public static func disabledServices(_ text: String) throws -> [String: Bool] {
        guard text.contains("disabled services = {"), text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("}") else {
            throw StartupError("launchctl did not return readable startup overrides.")
        }
        let expression = try NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*=>\s*(true|false)\s*;?\s*$"#)
        var result: [String: Bool] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "disabled services = {" || trimmed == "}" { continue }
            guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let label = Range(match.range(at: 1), in: line),
                  let state = Range(match.range(at: 2), in: line) else {
                throw StartupError("A launchctl startup override is unreadable. No enabled state was assumed.")
            }
            result[String(line[label])] = line[state] == "true"
        }
        return result
    }

    public static func backgroundItems(_ text: String, currentUID: UInt32) -> [StartupItem] {
        var uid: UInt32?
        var record: [String: String] = [:]
        var result: [StartupItem] = []

        func finish() {
            guard let uid, uid == 0 || uid == currentUID,
                  let uuid = record["UUID"], let name = record["Name"] else { return }
            let disposition = record["Disposition"] ?? ""
            let state: StartupState
            if let begin = disposition.firstIndex(of: "["), let end = disposition.firstIndex(of: "]"), begin < end {
                let flags = disposition[disposition.index(after: begin)..<end]
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                state = flags.contains("enabled") ? .enabled : .disabled
            } else { state = .unknown }
            let source = record["Executable Path"] ?? record["URL"] ?? record["Identifier"] ?? "Unavailable"
            let path = source.hasPrefix("file:") ? (URL(string: source)?.path ?? source) : source
            result.append(StartupItem(
                id: "background/\(uid)/\(uuid)", name: name, kind: .backgroundItem,
                domain: uid == 0 ? .system : .gui(uid), command: path, origin: record["Type"] ?? "macOS background item",
                state: state, restriction: "Managed by macOS. Use System Settings > General > Login Items.",
                source: .managedBackgroundItem(uuid)
            ))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") {
                finish()
                record.removeAll()
                let identifier = line.dropFirst("Records for UID".count).trimmingCharacters(in: .whitespaces)
                uid = identifier.hasPrefix("-") ? nil
                    : identifier.split(whereSeparator: { !$0.isNumber }).first.flatMap { UInt32($0) }
                continue
            }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if key == "UUID" { finish(); record.removeAll() }
            record[key] = value
        }
        finish()
        return result
    }
}
