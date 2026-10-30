import Darwin
import Foundation
import InstallCore
import SystemMetricsCore

extension SystemMetricsChecks {
    static func checkProcessInspection() {
        let fixture = [
            "p42", "cExample worker", "u501", "Lsample-user", "\nf4", "ar", "lR", "tREG",
            "D0x123", "s4096", "i100", "n/tmp/example file\nwith newline",
            "\nf5", "au", "l ", "tIPv6", "PTCP", "n[::1]:8080->[::1]:50000", "TST=ESTABLISHED",
            "\nf6", "aw", "tIPv4", "PTCP", "n*:8080", "TST=LISTEN",
            "\nf7", "au", "tIPv4", "PUDP", "n127.0.0.1:5353",
            "\np84", "cOther worker", "u0", "Lroot", "\nf3", "aw", "lW", "tREG", "s128", "n/tmp/locked",
            "\nf8", "tunix", "n/tmp/example.sock", ""
        ].joined(separator: "\0")
        let snapshot = ProcessInspectionParser.parseLsof(Data(fixture.utf8))
        check(snapshot.files.count == 3, "open-files parser lists files without treating IP sockets as files")
        check(snapshot.files.first?.path == "/tmp/example file\nwith newline", "NUL parsing preserves filename field boundaries")
        check(snapshot.files.first?.lock == "R", "open-files parser retains lock information")
        check(snapshot.files.first?.size == 4_096, "open-files parser retains size")
        check(snapshot.files.first?.descriptor == "4", "open-files parser retains file descriptor")
        check(snapshot.connections.count == 4, "connections include TCP, UDP, and Unix sockets")
        check(snapshot.connections.first?.local == "[::1]:8080", "IPv6 local endpoint remains intact")
        check(snapshot.connections.first?.remote == "[::1]:50000", "IPv6 remote endpoint remains intact")
        check(snapshot.connections[1].isListening, "TCP listening state is detected")
        check(snapshot.connections[2].state == "BOUND", "unconnected UDP is labelled bound, not listening TCP")
        check(snapshot.connections[3].protocolName == "Unix", "Unix socket protocol is explicit")

        let ownFiles = OpenFileQuery(userID: 501).apply(to: snapshot.files)
        check(ownFiles.count == 1, "open-file scope filters by numeric ownership")
        let lockSearch = OpenFileQuery(search: "locked", locksOnly: true).apply(to: snapshot.files)
        check(lockSearch.count == 1 && lockSearch[0].pid == 84, "open files support path search and lock filtering")
        check(
            OpenFileQuery(search: "42").apply(to: snapshot.files).count == 1,
            "open files support PID search"
        )
        check(
            OpenFileQuery(sort: .size, ascending: false).apply(to: snapshot.files).first?.size == 4_096,
            "open files sort by numeric size"
        )
        check(
            NetworkConnectionQuery(filter: .listening).apply(to: snapshot.connections).count == 1,
            "connection filter isolates listeners"
        )
        check(
            NetworkConnectionQuery(search: "::1", filter: .active).apply(to: snapshot.connections).count == 1,
            "active connections support endpoint search"
        )
        check(
            NetworkConnectionQuery(userID: 501).apply(to: snapshot.connections).count == 3,
            "connection scope filters by owner"
        )
        let orphan = ProcessInspectionParser.parseLsof(Data("f3\0tREG\0n/tmp/orphan\0".utf8))
        check(orphan.files.isEmpty, "file records without process ownership are rejected")
        checkLsofWithSyntheticResources()
    }

    private static func checkLsofWithSyntheticResources() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("killswitch-inspection-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: directory) }
                catch { check(false, "remove synthetic inspection resources: \(error.localizedDescription)") }
            }
            let file = directory.appendingPathComponent("synthetic caf\u{00e9} file\nwith newline.txt")
            try Data("synthetic fixture\n".utf8).write(to: file)
            let descriptor = Darwin.open(file.path, O_RDWR)
            guard descriptor >= 0 else { check(false, "open synthetic inspection file"); return }
            defer { Darwin.close(descriptor) }

            let listener = socket(AF_INET, SOCK_STREAM, 0)
            guard listener >= 0 else { check(false, "create synthetic loopback listener"); return }
            defer { Darwin.close(listener) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(listener, 1) == 0 else {
                check(false, "bind synthetic loopback listener"); return
            }

            let result = try CommandRunner.run(
                "/usr/sbin/lsof",
                arguments: ["-nP", "-b", "+c", "0", "-a", "-p", String(getpid()), "-F0pcuLfatDinsPT"],
                environment: ["LC_ALL": "en_US.UTF-8"]
            )
            let snapshot = ProcessInspectionParser.parseLsof(Data(result.standardOutput.utf8))
            check(result.succeeded, "lsof accepts the production machine-readable flags")
            let openFile = snapshot.files.first { $0.descriptor == String(descriptor) }
            check(openFile?.pid == getpid() && openFile?.userID == getuid(), "lsof associates the synthetic file with its process")
            check(
                openFile?.path.hasSuffix("synthetic caf\u{00e9} file\\nwith newline.txt") == true,
                "real lsof retains Unicode and spaces while representing control characters with documented escapes"
            )
            check(
                snapshot.connections.contains { $0.pid == getpid() && $0.descriptor == String(listener) && $0.isListening },
                "real lsof exposes the synthetic TCP listener"
            )
        } catch { check(false, "synthetic lsof integration: \(error.localizedDescription)") }
    }
}
