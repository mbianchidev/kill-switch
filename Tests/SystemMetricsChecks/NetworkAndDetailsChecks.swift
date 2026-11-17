import Foundation
import SystemMetricsCore

extension SystemMetricsChecks {
    static func checkNetworkDestinations() {
        check(NetworkAddress.split("192.0.2.10:443") == ("192.0.2.10", 443), "splits IPv4 endpoints")
        check(NetworkAddress.split("[2001:db8::5]:8443") == ("2001:db8::5", 8443), "splits bracketed IPv6 endpoints")
        check(NetworkAddress.normalized("::ffff:192.0.2.10") == "192.0.2.10" && NetworkAddress.normalized("fe80::1%en0") == "fe80::1",
              "unwraps IPv4-mapped addresses and drops IPv6 zones")
        check(NetworkAddress.identity("fe80::1%en0") == "fe80::1%en0" && NetworkAddress.identity("::ffff:192.0.2.10") == "192.0.2.10",
              "address identity keeps IPv6 zones and unwraps IPv4-mapped addresses")
        check(NetworkAddress.scope(of: "fe80::1%en0") == .linkLocal, "classifies zoned link-local addresses")
        let scopes: [(String, NetworkAddressScope)] = [
            ("10.1.2.3", .privateNetwork), ("172.16.0.1", .privateNetwork), ("172.32.0.1", .publicAddress),
            ("192.168.1.1", .privateNetwork), ("100.64.0.1", .sharedAddressSpace), ("169.254.1.1", .linkLocal),
            ("127.0.0.1", .loopback), ("224.0.0.251", .multicast), ("0.0.0.0", .unspecified), ("203.0.113.9", .publicAddress),
            ("::1", .loopback), ("::", .unspecified), ("fe80::1", .linkLocal), ("fd00::1", .privateNetwork),
            ("ff02::fb", .multicast), ("2001:db8::1", .publicAddress), ("not-an-address", .unknown)
        ]
        for (address, scope) in scopes {
            check(NetworkAddress.scope(of: address) == scope, "classifies \(address) as \(scope.rawValue)")
        }

        func process(_ pid: Int, _ name: String, _ sockets: [(String, String, String, String)]) -> [String] {
            ["p\(pid)", "c\(name)", "u501", "Lsynthetic-user"] + sockets.enumerated().flatMap { index, socket in
                ["\nf\(index + 3)", "t\(socket.0)", "P\(socket.1)", "n\(socket.2)", "TST=\(socket.3)"]
            }
        }
        let fields = process(100_001, "Synthetic Browser", [
            ("IPv4", "TCP", "10.0.0.2:50000->203.0.113.9:443", "ESTABLISHED"),
            ("IPv4", "TCP", "10.0.0.2:50001->203.0.113.9:80", "ESTABLISHED"),
            ("IPv6", "TCP", "[2001:db8::2]:50002->[2001:db8::9]:443", "ESTABLISHED"),
            ("IPv4", "TCP", "127.0.0.1:50003->127.0.0.1:5173", "ESTABLISHED"),
            ("IPv4", "TCP", "*:3000", "LISTEN"),
            ("IPv4", "TCP", "10.0.0.2:50004->198.51.100.1:443", "CLOSED")
        ]) + process(100_002, "Synthetic Sync", [
            ("IPv6", "TCP", "[::ffff:10.0.0.2]:50005->[::ffff:203.0.113.9]:443", "ESTABLISHED"),
            ("IPv6", "TCP", "[fe80::2%en0]:50006->[fe80::1%en0]:22", "ESTABLISHED"),
            ("IPv6", "TCP", "[fe80::2%en1]:50007->[fe80::1%en1]:22", "ESTABLISHED"),
            ("IPv4", "UDP", "10.0.0.2:5353", "")
        ]) + [""]
        let records = ProcessInspectionParser.parseLsof(Data(fields.joined(separator: "\0").utf8)).connections
        let destinations = NetworkDestinationGrouping.group(records, includeLoopback: false)
        check(destinations.map(\.address) == ["203.0.113.9", "2001:db8::9", "fe80::1%en0", "fe80::1%en1"],
              "groups active remote connections by address, excluding listeners, bound, closed, and loopback sockets")
        check(destinations.filter { $0.address.hasPrefix("fe80::1%") }.allSatisfy { $0.scope == .linkLocal && $0.connectionCount == 1 },
              "keeps link-local destinations on different interfaces apart")
        if let first = destinations.first {
            check(first.connectionCount == 3 && first.ports == [80, 443] && first.scope == .publicAddress
                  && first.processes.map(\.name) == ["Synthetic Browser", "Synthetic Sync"],
                  "merges IPv4-mapped connections and lists every process and remote port")
        }
        check(NetworkDestinationGrouping.group(records, includeLoopback: true).contains { $0.address == "127.0.0.1" },
              "can include loopback destinations")

        do {
            let interfaces = try NetworkInterfaceReader.addresses()
            let loopback = interfaces.first { $0.isLoopback && $0.family == "IPv4" }
            check(loopback?.address == "127.0.0.1" && loopback?.prefixLength == 8 && loopback?.scope == .loopback,
                  "reads interface addresses with prefix lengths")
            check(interfaces.allSatisfy { !$0.address.contains("%") }, "interface addresses omit IPv6 zone suffixes")
        } catch {
            check(false, "interface addresses: \(error.localizedDescription)")
        }
        check(ReverseDNS.hostname(for: "not-an-address") == nil, "reverse DNS rejects non-numeric input")
    }

    static func checkSystemDetails() {
        let json = #"""
        {"SPHardwareDataType": [{"_name": "hardware_overview", "machine_name": "Synthetic Mac", "machine_model": "Synthetic1,1",
          "model_number": "SYN001", "chip_type": "Synthetic Chip", "physical_memory": "16 GB"}],
         "SPDisplaysDataType": [{"_name": "Synthetic GPU", "spdisplays_ndrvs": [
           {"_name": "Built-in Display", "_spdisplays_resolution": "1512 x 982 @ 120.00Hz", "_spdisplays_pixels": "3024 x 1964",
            "spdisplays_main": "spdisplays_yes", "spdisplays_connection_type": "spdisplays_internal", "spdisplays_online": "spdisplays_yes"},
           {"_name": "Offline Display", "spdisplays_online": "spdisplays_no"},
           {"_name": "External Display", "_spdisplays_resolution": "2560 x 1440 @ 60.00Hz"}]}]}
        """#
        do {
            let hardware = try SystemDetailsParser.parseProfiler(Data(json.utf8))
            check(hardware.modelName == "Synthetic Mac" && hardware.modelIdentifier == "Synthetic1,1" && hardware.modelNumber == "SYN001",
                  "parses system_profiler hardware fields")
            check(hardware.displays.map(\.name) == ["Built-in Display", "External Display"]
                  && hardware.displays[0].isMain && hardware.displays[0].isBuiltIn && !hardware.displays[1].isBuiltIn
                  && hardware.displays[1].resolution == "2560 x 1440 @ 60.00Hz", "lists online displays")
            let empty = try SystemDetailsParser.parseProfiler(Data("{}".utf8))
            check(empty.modelName == nil && empty.displays.isEmpty, "missing profiler sections stay unavailable")
        } catch {
            check(false, "system_profiler fixture: \(error.localizedDescription)")
        }
        check((try? SystemDetailsParser.parseProfiler(Data("[]".utf8))) == nil, "rejects non-object profiler output")
        check(SystemDetailsParser.bootTime(seconds: 0, microseconds: 0) == nil
              && SystemDetailsParser.bootTime(seconds: 1_000, microseconds: 500_000) == Date(timeIntervalSince1970: 1_000.5),
              "converts boot time and rejects an unset value")
        let volume = SystemVolume(name: "Synthetic", path: "/synthetic", format: nil, totalBytes: 100,
                                  availableBytes: 30, isInternal: true, isRemovable: false)
        check(volume.usedBytes == 70 && volume.usedFraction == 0.7, "derives used volume space and share")
        func synthetic(_ total: UInt64?, _ available: UInt64?) -> SystemVolume {
            SystemVolume(name: "Synthetic", path: "/synthetic", format: nil, totalBytes: total, availableBytes: available,
                         isInternal: nil, isRemovable: nil)
        }
        check(synthetic(nil, 10).usedFraction == nil && synthetic(0, 0).usedFraction == nil && synthetic(10, 20).usedFraction == nil,
              "an unknown or inconsistent capacity has no used share rather than an invented one")
        check(SystemDetailsReader.volumes().contains { $0.path == "/" }, "lists the startup volume")
        check(SystemDetailsReader.startupVolume().flatMap(\.usedFraction).map { (0...1).contains($0) } == true,
              "reads the startup volume's used share")
    }
}
