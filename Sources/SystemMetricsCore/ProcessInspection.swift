import Foundation

public struct OpenFileRecord: Identifiable, Equatable, Sendable {
    public let pid: Int32
    public let process: String
    public let userID: UInt32
    public let user: String
    public let descriptor: String
    public let access: String
    public let lock: String
    public let kind: String
    public let path: String
    public let size: UInt64?
    public let inode: String
    public let device: String
    public var id: String { "\(pid)/\(descriptor)/\(device)/\(inode)/\(path)" }
    public var hasLock: Bool { !lock.trimmingCharacters(in: .whitespaces).isEmpty }

    public var accessDescription: String {
        switch access {
        case "r": return "Read"
        case "w": return "Write"
        case "u": return "Read/write"
        default: return "Unknown"
        }
    }

    public var lockDescription: String {
        switch lock {
        case "r": return "Read (partial)"
        case "R": return "Read"
        case "w": return "Write (partial)"
        case "W": return "Write"
        case "u": return "Read/write"
        case "U": return "Unknown lock"
        case "x", "X": return "Exclusive"
        default: return hasLock ? lock : "None reported"
        }
    }
}

public struct NetworkConnectionRecord: Identifiable, Equatable, Sendable {
    public let pid: Int32
    public let process: String
    public let userID: UInt32
    public let user: String
    public let descriptor: String
    public let protocolName: String
    public let family: String
    public let local: String
    public let remote: String?
    public let state: String
    public var id: String { "\(pid)/\(descriptor)/\(protocolName)/\(local)/\(remote ?? "")" }
    public var isListening: Bool { state == "LISTEN" }
    public var isActive: Bool { remote != nil && state != "CLOSED" && !isListening }
}

public struct ProcessInspectionSnapshot: Sendable {
    public let files: [OpenFileRecord]
    public let connections: [NetworkConnectionRecord]
}

public enum ProcessInspectionParser {
    public static let lsofFields = "-F0pcuLfaltDinsPT"
    public static let lsofArguments = ["-nP", "-S", "2", "+c", "0", lsofFields]

    public static func parseLsof(_ data: Data) -> ProcessInspectionSnapshot {
        var files: [OpenFileRecord] = []
        var connections: [NetworkConnectionRecord] = []
        var pid: Int32?
        var process = ""
        var userID: UInt32?
        var user = ""
        var fields: [Character: String] = [:]
        var state = ""

        func finishFile() {
            guard let pid, let userID, let descriptor = fields["f"], let path = fields["n"] else { return }
            let kind = fields["t"] ?? "Unknown"
            if ["IPv4", "IPv6", "unix"].contains(kind) {
                let endpoints = path.components(separatedBy: "->")
                let remote = endpoints.count > 1 ? endpoints.dropFirst().joined(separator: "->") : nil
                let protocolName = kind == "unix" ? "Unix" : (fields["P"] ?? kind)
                connections.append(NetworkConnectionRecord(
                    pid: pid, process: process, userID: userID, user: user,
                    descriptor: descriptor, protocolName: protocolName, family: kind,
                    local: endpoints[0], remote: remote,
                    state: state.isEmpty ? (remote == nil ? "BOUND" : "CONNECTED") : state
                ))
            }
            if kind != "IPv4" && kind != "IPv6" {
                files.append(OpenFileRecord(
                    pid: pid, process: process, userID: userID, user: user,
                    descriptor: descriptor, access: fields["a"] ?? "", lock: fields["l"] ?? "",
                    kind: kind, path: path, size: fields["s"].flatMap(UInt64.init),
                    inode: fields["i"] ?? "", device: fields["D"] ?? ""
                ))
            }
        }

        for token in data.split(separator: 0) {
            let field = String(decoding: token, as: UTF8.self).drop(while: { $0 == "\n" })
            guard let tag = field.first else { continue }
            let value = String(field.dropFirst())
            switch tag {
            case "p":
                finishFile()
                fields.removeAll(keepingCapacity: true)
                state = ""
                pid = Int32(value)
                process = ""
                userID = nil
                user = ""
            case "c": process = value
            case "u":
                userID = UInt32(value)
                if user.isEmpty { user = value }
            case "L": user = value
            case "f":
                finishFile()
                fields = ["f": value]
                state = ""
            case "T":
                if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: fields[tag] = value
            }
        }
        finishFile()
        return ProcessInspectionSnapshot(files: files, connections: connections)
    }
}

public enum OpenFileSort: String, CaseIterable, Identifiable, Sendable {
    case path = "Path"
    case process = "Process"
    case pid = "PID"
    case descriptor = "Descriptor"
    case size = "Size"
    case lock = "Lock"
    public var id: Self { self }
}

public struct OpenFileQuery {
    public var search: String
    public var userID: UInt32?
    public var pid: Int32?
    public var locksOnly: Bool
    public var kind: String?
    public var sort: OpenFileSort
    public var ascending: Bool

    public init(
        search: String = "", userID: UInt32? = nil, pid: Int32? = nil,
        locksOnly: Bool = false, kind: String? = nil, sort: OpenFileSort = .path, ascending: Bool = true
    ) {
        self.search = search
        self.userID = userID
        self.pid = pid
        self.locksOnly = locksOnly
        self.kind = kind
        self.sort = sort
        self.ascending = ascending
    }

    public func apply(to files: [OpenFileRecord]) -> [OpenFileRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return files.filter { file in
            (userID == nil || file.userID == userID) && (pid == nil || file.pid == pid)
                && (!locksOnly || file.hasLock) && (kind == nil || file.kind == kind)
                && (query.isEmpty || [file.path, file.process, file.user, String(file.pid)]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
                    || (file.hasLock && file.lockDescription.localizedCaseInsensitiveContains(query)))
        }.sorted { left, right in
            let comparison: ComparisonResult
            switch sort {
            case .size: comparison = compare(left.size, right.size)
            case .pid: comparison = compare(left.pid, right.pid)
            case .descriptor:
                comparison = left.descriptor.localizedStandardCompare(right.descriptor)
            case .path: comparison = left.path.localizedStandardCompare(right.path)
            case .process: comparison = left.process.localizedStandardCompare(right.process)
            case .lock: comparison = left.lockDescription.localizedStandardCompare(right.lockDescription)
            }
            let order = comparison == .orderedSame ? left.id.compare(right.id) : comparison
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

public enum NetworkConnectionFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All sockets"
    case listening = "Listening"
    case active = "Active"
    public var id: Self { self }
}

public enum NetworkConnectionSort: String, CaseIterable, Identifiable, Sendable {
    case process = "Process"
    case pid = "PID"
    case local = "Local endpoint"
    case remote = "Remote endpoint"
    case state = "State"
    case protocolName = "Protocol"
    public var id: Self { self }
}

public struct NetworkConnectionQuery {
    public var search: String
    public var userID: UInt32?
    public var filter: NetworkConnectionFilter
    public var sort: NetworkConnectionSort
    public var ascending: Bool

    public init(
        search: String = "", userID: UInt32? = nil, filter: NetworkConnectionFilter = .all,
        sort: NetworkConnectionSort = .process, ascending: Bool = true
    ) {
        self.search = search
        self.userID = userID
        self.filter = filter
        self.sort = sort
        self.ascending = ascending
    }

    public func apply(to connections: [NetworkConnectionRecord]) -> [NetworkConnectionRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return connections.filter { row in
            (userID == nil || row.userID == userID)
                && (filter != .listening || row.isListening) && (filter != .active || row.isActive)
                && (query.isEmpty || [
                    row.process, String(row.pid), row.user, row.local, row.remote ?? "", row.state, row.protocolName
                ].contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { left, right in
            let comparison: ComparisonResult
            switch sort {
            case .pid: comparison = compare(left.pid, right.pid)
            case .process: comparison = left.process.localizedStandardCompare(right.process)
            case .local: comparison = left.local.localizedStandardCompare(right.local)
            case .remote: comparison = (left.remote ?? "").localizedStandardCompare(right.remote ?? "")
            case .state: comparison = left.state.compare(right.state)
            case .protocolName: comparison = left.protocolName.compare(right.protocolName)
            }
            let order = comparison == .orderedSame ? left.id.compare(right.id) : comparison
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

private func compare<T: Comparable>(_ left: T?, _ right: T?) -> ComparisonResult {
    switch (left, right) {
    case let (left?, right?): return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
    case (nil, nil): return .orderedSame
    case (nil, _): return .orderedAscending
    case (_, nil): return .orderedDescending
    }
}
