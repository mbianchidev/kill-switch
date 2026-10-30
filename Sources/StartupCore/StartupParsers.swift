import Foundation

public struct BackgroundItemInventory: Sendable {
    public let items: [StartupItem]
    public let recognized: Bool
}

public enum StartupParsers {
    public static func disabledServices(_ text: String) throws -> [String: Bool] {
        guard let header = text.range(
            of: #"(?m)^[ \t]*disabled services[ \t]*=[ \t]*\{[ \t]*\r?$"#,
            options: .regularExpression
        ) else {
            throw StartupError("launchctl did not return readable startup overrides.")
        }
        let remaining = String(text[header.upperBound...])
        guard let closing = remaining.range(of: #"(?m)^[ \t]*\}[ \t]*\r?$"#, options: .regularExpression) else {
            throw StartupError("The launchctl startup override block is incomplete.")
        }
        let block = remaining[..<closing.lowerBound]
        let expression = try NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*=>\s*(true|false|enabled|disabled)\s*;?\s*$"#)
        var result: [String: Bool] = [:]
        for line in block.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let label = Range(match.range(at: 1), in: line),
                  let state = Range(match.range(at: 2), in: line) else {
                throw StartupError("A launchctl startup override is unreadable. No enabled state was assumed.")
            }
            result[String(line[label])] = line[state] == "true" || line[state] == "disabled"
        }
        return result
    }

    public static func loginItems(
        saved: [LegacyLoginItem], live: [LegacyLoginItem]?, currentUID: UInt32
    ) -> [StartupItem] {
        var records: [String: LegacyLoginItem] = [:]
        for item in saved { records[item.id] = item }
        for item in live ?? [] { records[item.id] = item }
        let liveGroups = Dictionary(grouping: live ?? [], by: \.id)
        return records.values.map { login in
            let enabled = liveGroups[login.id] != nil
            let state: StartupState = live == nil ? .unknown : (enabled ? .enabled : .disabled)
            let restriction: String?
            if live == nil {
                restriction = "Load login apps to verify whether this saved registration is currently disabled."
            } else if (liveGroups[login.id]?.count ?? 0) > 1 {
                restriction = "Multiple login registrations share this name and path. Manage them in macOS Login Items settings."
            } else { restriction = nil }
            return StartupItem(
                id: login.id, name: login.name, kind: .loginApp, domain: .gui(currentUID),
                command: login.path, origin: live == nil ? "Saved login app; verification required" : "Legacy login item",
                state: state, restriction: restriction, source: .loginItem(login)
            )
        }.sorted { $0.id < $1.id }
    }

    public static func backgroundItems(_ text: String, currentUID: UInt32) -> [StartupItem] {
        backgroundInventory(text, currentUID: currentUID).items
    }

    public static func backgroundInventory(_ text: String, currentUID: UInt32) -> BackgroundItemInventory {
        var uid: Int64?
        var record: [String: String] = [:]
        var result: [StartupItem] = []
        var sawSection = false
        var invalidRecord = false

        func finish() {
            guard record["UUID"] != nil else { return }
            guard let uid, let uuid = record["UUID"], let name = record["Name"] else {
                invalidRecord = true
                return
            }
            guard uid == 0 || uid == Int64(currentUID) else { return }
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
                domain: uid == 0 ? .system : .gui(currentUID), command: path, origin: record["Type"] ?? "macOS background item",
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
                let number = identifier.prefix { $0 == "-" || $0.isNumber }
                uid = Int64(number)
                if uid != nil { sawSection = true }
                continue
            }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if key == "UUID" { finish(); record.removeAll() }
            record[key] = value
        }
        finish()
        return BackgroundItemInventory(items: result, recognized: sawSection && !invalidRecord)
    }
}
