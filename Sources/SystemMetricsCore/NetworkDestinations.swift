import Darwin
import Foundation

public enum NetworkAddressScope: String, CaseIterable, Sendable {
    case publicAddress = "Public"
    case privateNetwork = "Private"
    case sharedAddressSpace = "Carrier-grade NAT"
    case linkLocal = "Link-local"
    case loopback = "Loopback"
    case multicast = "Multicast"
    case unspecified = "Unspecified"
    case unknown = "Unknown"
}

public enum NetworkAddress {
    /// Splits lsof endpoints such as `192.0.2.1:443` or `[2001:db8::1]:443`.
    public static func split(_ endpoint: String) -> (host: String, port: UInt16?) {
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
            let rest = endpoint[endpoint.index(after: close)...]
            return (host, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) : nil)
        }
        guard let separator = endpoint.lastIndex(of: ":"),
              endpoint[..<separator].contains(":") == false else {
            return (endpoint, nil)
        }
        return (String(endpoint[..<separator]), UInt16(endpoint[endpoint.index(after: separator)...]))
    }

    /// Removes an IPv6 zone (`fe80::1%en0`) and unwraps IPv4-mapped IPv6 addresses.
    public static func normalized(_ host: String) -> String {
        let withoutZone = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        let lowered = withoutZone.lowercased()
        if lowered.hasPrefix("::ffff:"), isIPv4(String(lowered.dropFirst("::ffff:".count))) {
            return String(lowered.dropFirst("::ffff:".count))
        }
        return withoutZone
    }

    public static func isIPv4(_ host: String) -> Bool {
        var address = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }

    public static func scope(of rawHost: String) -> NetworkAddressScope {
        let host = normalized(rawHost)
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            let first = value >> 24, second = (value >> 16) & 0xff
            switch first {
            case 0: return .unspecified
            case 10: return .privateNetwork
            case 127: return .loopback
            case 100 where (64...127).contains(second): return .sharedAddressSpace
            case 169 where second == 254: return .linkLocal
            case 172 where (16...31).contains(second): return .privateNetwork
            case 192 where second == 168: return .privateNetwork
            case 224...239: return .multicast
            default: return .publicAddress
            }
        }
        var v6 = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return .unknown }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes.allSatisfy({ $0 == 0 }) { return .unspecified }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return .loopback }
        if bytes[0] == 0xff { return .multicast }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return .linkLocal }
        if bytes[0] & 0xfe == 0xfc { return .privateNetwork }
        return .publicAddress
    }
}

public struct NetworkDestinationProcess: Hashable, Sendable {
    public let pid: Int32
    public let name: String
    public let user: String
}

/// Live connections from this Mac to one remote address.
public struct NetworkDestination: Identifiable, Equatable, Sendable {
    public var id: String { address }

    public let address: String
    public let scope: NetworkAddressScope
    public let ports: [UInt16]
    public let protocols: [String]
    public let states: [String]
    public let connectionCount: Int
    public let processes: [NetworkDestinationProcess]
}

public enum NetworkDestinationGrouping {
    /// Groups active IPv4/IPv6 connections by normalized remote address. Listeners, bound
    /// sockets, and Unix sockets have no remote endpoint and are excluded.
    public static func group(_ records: [NetworkConnectionRecord], includeLoopback: Bool) -> [NetworkDestination] {
        var groups: [String: [NetworkConnectionRecord]] = [:]
        for record in records where record.isActive && record.family != "unix" {
            guard let remote = record.remote else { continue }
            let host = NetworkAddress.normalized(NetworkAddress.split(remote).host)
            guard !host.isEmpty, host != "*" else { continue }
            if !includeLoopback, NetworkAddress.scope(of: host) == .loopback { continue }
            groups[host, default: []].append(record)
        }
        return groups.map { address, records in
            let processes = Set(records.map { NetworkDestinationProcess(pid: $0.pid, name: $0.process, user: $0.user) })
            return NetworkDestination(
                address: address,
                scope: NetworkAddress.scope(of: address),
                ports: Set(records.compactMap { $0.remote.flatMap { NetworkAddress.split($0).port } }).sorted(),
                protocols: Set(records.map(\.protocolName)).sorted(),
                states: Set(records.map(\.state)).sorted(),
                connectionCount: records.count,
                processes: processes.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending || ($0.name == $1.name && $0.pid < $1.pid)
                }
            )
        }
        .sorted {
            $0.connectionCount != $1.connectionCount
                ? $0.connectionCount > $1.connectionCount
                : $0.address.localizedStandardCompare($1.address) == .orderedAscending
        }
    }
}

public struct NetworkInterfaceAddress: Identifiable, Equatable, Sendable {
    public var id: String { "\(interface)/\(address)" }

    public let interface: String
    public let family: String
    public let address: String
    public let prefixLength: Int?
    public let isUp: Bool
    public let isLoopback: Bool
    public let scope: NetworkAddressScope

    public init(interface: String, family: String, address: String, prefixLength: Int?, isUp: Bool, isLoopback: Bool) {
        self.interface = interface
        self.family = family
        self.address = address
        self.prefixLength = prefixLength
        self.isUp = isUp
        self.isLoopback = isLoopback
        scope = NetworkAddress.scope(of: address)
    }
}

public enum NetworkInterfaceReader {
    /// Reads this Mac's IPv4 and IPv6 interface addresses with `getifaddrs`.
    public static func addresses() throws -> [NetworkInterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            throw ProcessInspectionError(message: "Network interfaces could not be read: \(String(cString: strerror(errno)))")
        }
        defer { freeifaddrs(head) }
        var result: [NetworkInterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socketAddress = entry.ifa_addr else { continue }
            let family = Int32(socketAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6, let address = numericHost(socketAddress) else { continue }
            let flags = Int32(entry.ifa_flags)
            result.append(NetworkInterfaceAddress(
                interface: String(cString: entry.ifa_name),
                family: family == AF_INET ? "IPv4" : "IPv6",
                address: NetworkAddress.normalized(address),
                prefixLength: entry.ifa_netmask.flatMap { prefixLength($0, family: family) },
                isUp: flags & IFF_UP != 0,
                isLoopback: flags & IFF_LOOPBACK != 0
            ))
        }
        return result.sorted {
            ($0.interface, $0.family, $0.address) < ($1.interface, $1.family, $1.address)
        }
    }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.pointee.sa_len)
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    /// Counts mask bits from the bytes actually present; macOS may shorten IPv4 netmask
    /// sockaddrs and leave their family unset.
    private static func prefixLength(_ mask: UnsafeMutablePointer<sockaddr>, family: Int32) -> Int? {
        let length = Int(mask.pointee.sa_len)
        let range: Range<Int>
        if family == AF_INET {
            range = 4..<min(max(length, 4), 8)
        } else {
            let start = MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr) ?? 8
            range = start..<min(max(length, start), start + 16)
        }
        guard length > 0 else { return nil }
        let raw = UnsafeRawPointer(mask)
        return range.reduce(0) { $0 + raw.load(fromByteOffset: $1, as: UInt8.self).nonzeroBitCount }
    }
}

public enum ReverseDNS {
    /// Looks up the PTR name for a numeric address; blocks, so call it off the main thread.
    /// Returns nil when no name exists or the lookup fails.
    public static func hostname(for host: String) -> String? {
        let address = NetworkAddress.normalized(host)
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &info) == 0, let first = info, let socketAddress = first.pointee.ai_addr else {
            return nil
        }
        defer { freeaddrinfo(info) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(socketAddress, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD) == 0 else {
            return nil
        }
        let name = String(cString: buffer)
        return name == address ? nil : name
    }
}
