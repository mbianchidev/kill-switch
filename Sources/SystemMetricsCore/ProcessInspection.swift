import Darwin
import Foundation
import TableQueryCore

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
    public var protocolDescription: String { family == "unix" ? protocolName : "\(protocolName) \(family)" }
    public var localPort: UInt16? { port(in: local) }
    public var remotePort: UInt16? { port(in: remote) }

    public var browserURL: URL? {
        guard isListening, protocolName == "TCP", let port = localPort, port > 0,
              let separator = local.lastIndex(of: ":") else { return nil }
        var host = String(local[..<separator])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        switch family {
        case "IPv4":
            if host == "*" || host == "0.0.0.0" { host = "127.0.0.1" }
            var address = in_addr()
            guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        case "IPv6":
            if host == "*" || host == "::" { host = "::1" }
            var address = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
            host = "[\(host)]"
        default: return nil
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        return components.url
    }

    private func port(in endpoint: String?) -> UInt16? {
        guard family != "unix", let last = endpoint?.split(separator: ":").last else { return nil }
        return UInt16(last)
    }
}

public struct ProcessInspectionSnapshot: Sendable {
    public let files: [OpenFileRecord]
    public let connections: [NetworkConnectionRecord]
}

public struct ProcessInspectionError: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ProcessInspectionParser {
    public static let lsofFields = "-F0pcuLfaltDinsPT"
    public static let lsofArguments = ["-nP", "-S", "2", "+c", "0", lsofFields]

    public static func arguments(
        pid: Int32? = nil, connectionsOnly: Bool = false, listenersOnly: Bool = false
    ) throws -> [String] {
        if let pid {
            guard pid > 0 else { throw ProcessInspectionError(message: "A positive process ID is required.") }
            return lsofArguments + ["-a", "-p", String(pid)]
        }
        if listenersOnly { return lsofArguments + ["-iTCP", "-sTCP:LISTEN"] }
        return lsofArguments + (connectionsOnly ? ["-i", "-U"] : [])
    }

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
    case user = "User"
    case access = "Access"
    case kind = "Type"
    public var id: Self { self }

    var field: TableField<OpenFileRecord> {
        switch self {
        case .path: return OpenFileTableFields.path
        case .process: return OpenFileTableFields.process
        case .pid: return OpenFileTableFields.pid
        case .descriptor: return OpenFileTableFields.descriptor
        case .size: return OpenFileTableFields.size
        case .lock: return OpenFileTableFields.lock
        case .user: return OpenFileTableFields.user
        case .access: return OpenFileTableFields.access
        case .kind: return OpenFileTableFields.kind
        }
    }
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

    public var tableQuery: TableQuery<OpenFileRecord> { TableQuery(search: search, fields: OpenFileTableFields.all) }

    public func matching(_ files: [OpenFileRecord]) -> [OpenFileRecord] { tableQuery.filter(scoped(files)) }

    public func apply(to files: [OpenFileRecord]) -> [OpenFileRecord] {
        tableQuery.apply(
            to: scoped(files), sorting: TableComparator(field: sort.field, order: ascending ? .forward : .reverse),
            identity: \.id
        )
    }

    private func scoped(_ files: [OpenFileRecord]) -> [OpenFileRecord] {
        files.filter { file in
            (userID == nil || file.userID == userID) && (pid == nil || file.pid == pid)
                && (!locksOnly || file.hasLock) && (kind == nil || file.kind == kind)
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
    case user = "User"
    public var id: Self { self }

    var field: TableField<NetworkConnectionRecord> {
        switch self {
        case .process: return ConnectionTableFields.process
        case .pid: return ConnectionTableFields.pid
        case .local: return ConnectionTableFields.local
        case .remote: return ConnectionTableFields.remote
        case .state: return ConnectionTableFields.state
        case .protocolName: return ConnectionTableFields.protocolName
        case .user: return ConnectionTableFields.user
        }
    }
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

    public var tableQuery: TableQuery<NetworkConnectionRecord> { TableQuery(search: search, fields: ConnectionTableFields.all) }

    public func matching(_ connections: [NetworkConnectionRecord]) -> [NetworkConnectionRecord] {
        tableQuery.filter(scoped(connections))
    }

    public func apply(to connections: [NetworkConnectionRecord]) -> [NetworkConnectionRecord] {
        tableQuery.apply(
            to: scoped(connections), sorting: TableComparator(field: sort.field, order: ascending ? .forward : .reverse),
            identity: \.id
        )
    }

    private func scoped(_ connections: [NetworkConnectionRecord]) -> [NetworkConnectionRecord] {
        connections.filter { row in
            (userID == nil || row.userID == userID)
                && (filter != .listening || row.isListening) && (filter != .active || row.isActive)
        }
    }
}
