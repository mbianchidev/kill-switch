import Foundation
import Darwin
import SystemMetricsCore
import os

extension SystemMetricsChecks {
    static func checkDeveloperListeners() {
        let fixture = [
            "p42", "cSynthetic server", "u501", "Lsynthetic-user",
            "\nf4", "tIPv4", "PTCP", "n*:8080", "TST=LISTEN",
            "\nf5", "tIPv6", "PTCP", "n[::]:8080", "TST=LISTEN",
            "\nf6", "tIPv4", "PTCP", "n127.0.0.1:8000->127.0.0.1:80", "TST=ESTABLISHED",
            "\nf7", "tIPv4", "PTCP", "nmalformed.invalid:9000", "TST=LISTEN", ""
        ].joined(separator: "\0")
        let connections = ProcessInspectionParser.parseLsof(Data(fixture.utf8)).connections
        check(connections[0].browserURL?.absoluteString == "http://127.0.0.1:8080", "wildcard IPv4 listeners open on loopback")
        check(connections[1].browserURL?.absoluteString == "http://[::1]:8080", "wildcard IPv6 listeners use a bracketed loopback URL")
        check(connections[2].browserURL == nil, "active connections are not offered as local web servers")
        check(connections[3].browserURL == nil, "untrusted endpoint text cannot create an external browser URL")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("killswitch-project-check-\(UUID().uuidString)")
        do {
            let project = root.appendingPathComponent("synthetic-project")
            let cwd = project.appendingPathComponent("src/nested")
            let git = project.appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: root) }
                catch { check(false, "remove synthetic project fixtures: \(error.localizedDescription)") }
            }
            try Data("ref: refs/heads/synthetic-feature\n".utf8).write(to: git.appendingPathComponent("HEAD"))
            let resolved = try DevelopmentProjectResolver.resolve(cwd)
            check(resolved.directory.path == project.path && resolved.branch == "synthetic-feature", "listeners resolve the nearest Git project without running git")
            do {
                _ = try DevelopmentProjectResolver.resolve(cwd, shouldContinue: { false })
                check(false, "canceled project discovery must not start filesystem inspection")
            } catch {
                check(error is CancellationError, "canceled project discovery reports cancellation, not an unavailable Git reading")
            }
            let admissionChecks = OSAllocatedUnfairLock(initialState: 0)
            do {
                _ = try DevelopmentProjectResolver.resolve(cwd, shouldContinue: {
                    admissionChecks.withLock { $0 += 1; return $0 < 3 }
                })
                check(false, "project discovery must recheck admission between metadata lookups")
            } catch {
                check(error is CancellationError && admissionChecks.withLock({ $0 }) == 3,
                      "mid-discovery cancellation stops at the first rejected metadata admission")
            }

            let worktree = root.appendingPathComponent("synthetic-worktree")
            let metadata = root.appendingPathComponent("synthetic-metadata")
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            try Data("gitdir: ../synthetic-metadata\n".utf8).write(to: worktree.appendingPathComponent(".git"))
            try Data("0123456789abcdef0123456789abcdef01234567\n".utf8).write(to: metadata.appendingPathComponent("HEAD"))
            let detached = try DevelopmentProjectResolver.resolve(worktree)
            check(detached.directory.path == worktree.path && detached.branch == "Detached 01234567", "worktree gitdir files and detached heads are supported")

            for suffix in [" ", "\t", "\u{00A0}"] {
                let whitespaceMetadata = root.appendingPathComponent("synthetic-metadata\(suffix)")
                try FileManager.default.createDirectory(at: whitespaceMetadata, withIntermediateDirectories: false)
                try Data("ref: refs/heads/whitespace-fixture\n".utf8).write(to: whitespaceMetadata.appendingPathComponent("HEAD"))
                for ending in ["\n", "\r\n", ""] {
                    for path in ["../\(whitespaceMetadata.lastPathComponent)", whitespaceMetadata.path] {
                        try Data("gitdir: \(path)\(ending)".utf8).write(to: worktree.appendingPathComponent(".git"))
                        let context = try DevelopmentProjectResolver.resolve(worktree)
                        check(context.directory.path == worktree.path && context.branch == "whitespace-fixture",
                              "Git directory pointers preserve path whitespace with LF, CRLF, or no terminator")
                    }
                }
            }
            try Data(" gitdir: ../synthetic-metadata\n".utf8).write(to: worktree.appendingPathComponent(".git"))
            do {
                _ = try DevelopmentProjectResolver.resolve(worktree)
                check(false, "Git directory pointers must not normalize an invalid leading prefix")
            } catch {
                check(error is DevelopmentProjectMetadataError, "invalid Git directory prefixes retain a metadata error")
            }
            try Data("gitdir: ../synthetic-metadata\n".utf8).write(to: worktree.appendingPathComponent(".git"))

            let head = metadata.appendingPathComponent("HEAD")
            for contents in [" ref: refs/heads/synthetic-feature\n", "ref: refs/heads/synthetic-feature \n",
                             " \(String(repeating: "a", count: 40))\n", "\(String(repeating: "a", count: 40)) \n"] {
                try Data(contents.utf8).write(to: head)
                do {
                    _ = try DevelopmentProjectResolver.resolve(worktree)
                    check(false, "Git HEAD whitespace must not be normalized into a different valid identity")
                } catch {
                    check(error is DevelopmentProjectMetadataError, "invalid Git HEAD whitespace retains a metadata error")
                }
            }
            try Data("ref: refs/heads/synthetic-feature\u{00A0}\r\n".utf8).write(to: head)
            let whitespaceBranch = try DevelopmentProjectResolver.resolve(worktree)
            check(whitespaceBranch.branch == "synthetic-feature\u{00A0}", "valid non-ASCII branch whitespace remains part of the name")

            for length in 39...65 where length != 40 && length != 64 {
                try Data((String(repeating: "a", count: length) + "\n").utf8).write(to: head)
                do {
                    _ = try DevelopmentProjectResolver.resolve(worktree)
                    check(false, "detached Git IDs must reject invalid length \(length)")
                } catch { check(true, "detached Git IDs must reject invalid length \(length)") }
            }
            try Data((String(repeating: "b", count: 64) + "\n").utf8).write(to: head)
            let sha256 = try DevelopmentProjectResolver.resolve(worktree)
            check(sha256.branch == "Detached bbbbbbbb", "SHA-256 detached Git IDs must remain supported")
            let reftable = metadata.appendingPathComponent("reftable")
            try FileManager.default.createDirectory(at: reftable, withIntermediateDirectories: false)
            try Data("ref: refs/heads/.invalid\n".utf8).write(to: head)
            do {
                _ = try DevelopmentProjectResolver.resolve(worktree.appendingPathComponent("nested/worker"))
                check(false, "unsupported reftable metadata must not invent a branch from its compatibility HEAD")
            } catch {
                check(error.localizedDescription.lowercased().contains("reftable")
                      && (error as? DevelopmentProjectMetadataError)?.project.directory.path == worktree.path,
                      "unsupported reftable metadata must retain the discovered repository root and its specific error")
            }
            try FileManager.default.removeItem(at: reftable)
            try Data("malformed synthetic HEAD\n".utf8).write(to: head)
            do {
                _ = try DevelopmentProjectResolver.resolve(worktree.appendingPathComponent("nested/worker"))
                check(false, "malformed branch metadata must report discovery failure")
            } catch {
                check((error as? DevelopmentProjectMetadataError)?.project.directory.path == worktree.path,
                      "malformed branch metadata must retain the root found above a nested working directory")
            }
            for name in ["bad branch", "bad..branch", "bad@{branch", ".hidden", "nested/.hidden",
                         "nested/name.lock", "bad//branch", "bad/", "bad.", "bad~name", "bad^name",
                         "bad:name", "bad?name", "bad*name", "bad[name", "bad\\name", "-branch"] {
                try Data("ref: refs/heads/\(name)\n".utf8).write(to: head)
                do {
                    _ = try DevelopmentProjectResolver.resolve(worktree)
                    check(false, "malformed Git branch refs must reject \(name)")
                } catch {
                    check(error is DevelopmentProjectMetadataError, "malformed Git branch refs retain metadata errors for \(name)")
                }
            }
            try Data("ref: refs/heads/feature/synthetic\n".utf8).write(to: head)
            let nestedBranch = try DevelopmentProjectResolver.resolve(worktree)
            check(nestedBranch.branch == "feature/synthetic", "valid nested Git branch refs remain supported")
            try Data((String(repeating: "\u{FF21}", count: 40) + "\n").utf8).write(to: head)
            do {
                _ = try DevelopmentProjectResolver.resolve(worktree)
                check(false, "detached Git IDs must reject non-ASCII hexadecimal lookalikes")
            } catch { check(true, "detached Git IDs must reject non-ASCII hexadecimal lookalikes") }
            try FileManager.default.removeItem(at: head)
            try FileManager.default.createSymbolicLink(at: head, withDestinationURL: git.appendingPathComponent("HEAD"))
            do {
                _ = try DevelopmentProjectResolver.resolve(worktree)
                check(false, "project resolution must not follow a symlink HEAD")
            } catch { check(true, "project resolution must not follow a symlink HEAD") }
            try FileManager.default.removeItem(at: head)
            try Data(repeating: 65, count: 4_097).write(to: head)
            do {
                _ = try DevelopmentProjectResolver.resolve(worktree)
                check(false, "project metadata reads must be bounded")
            } catch { check(true, "project metadata reads must be bounded") }
            try FileManager.default.removeItem(at: head)
            guard mkfifo(head.path, 0o600) == 0 else {
                check(false, "create synthetic FIFO Git metadata")
                return
            }
            do {
                _ = try DevelopmentProjectResolver.resolve(worktree)
                check(false, "a FIFO HEAD must not block project discovery")
            } catch { check(true, "a FIFO HEAD must not block project discovery") }

            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            child.currentDirectoryURL = cwd
            try child.run()
            defer {
                if child.isRunning { child.terminate() }
                child.waitUntilExit()
            }
            if let identity = ProcessLifetimeReader.read(pid: child.processIdentifier, bootSession: "synthetic-check-boot") {
                let directory = try ProcessWorkingDirectoryReader.read(identity)
                check(directory.path == cwd.resolvingSymlinksInPath().path, "native working-directory reads use only the benchmark-owned synthetic process")
            } else { check(false, "identify the synthetic working-directory process") }
        } catch { check(false, "synthetic development project resolution: \(error.localizedDescription)") }
    }
}
