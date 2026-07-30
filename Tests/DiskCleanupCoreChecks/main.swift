import DiskCleanupCore
import Foundation

struct CheckRunner {
    private var failures = 0
    private let fileManager = FileManager.default

    mutating func run() -> Int32 {
        check(
            DiskCleanupError.invalidScanLocation("/tmp/example").localizedDescription
                == "Refusing to scan this cleanup location: /tmp/example",
            "describes rejected scan locations without assuming they are outside the root"
        )

        let fixtureRoot = fileManager.temporaryDirectory
            .appendingPathComponent("DiskCleanupCoreChecks-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        do {
            try fileManager.createDirectory(
                at: fixtureRoot,
                withIntermediateDirectories: true
            )
            try checkScanning(in: fixtureRoot)
            try checkCancellation(in: fixtureRoot)
            try checkIncompleteFolderProtection(in: fixtureRoot)
            try checkTrashSafety(in: fixtureRoot)
        } catch {
            fail("fixture setup: \(error.localizedDescription)")
        }

        if failures == 0 {
            print("All DiskCleanupCore checks passed.")
            return 0
        }
        fputs("\(failures) DiskCleanupCore check(s) failed.\n", stderr)
        return 1
    }

    private mutating func checkScanning(in fixtureRoot: URL) throws {
        let roots = try makeRoots(in: fixtureRoot.appendingPathComponent("scan", isDirectory: true))
        let downloads = roots.home.appendingPathComponent("Downloads", isDirectory: true)
        let movies = roots.home.appendingPathComponent("Movies", isDirectory: true)
        let hidden = roots.home.appendingPathComponent(".hidden", isDirectory: true)
        try createDirectory(downloads)
        try createDirectory(movies)
        try createDirectory(hidden)
        try createDirectory(downloads.appendingPathComponent(".git/objects", isDirectory: true))

        try writeFile(downloads.appendingPathComponent("medium.bin"), bytes: 32 * 1024)
        try writeFile(downloads.appendingPathComponent("small.bin"), bytes: 8 * 1024)
        try writeFile(
            downloads.appendingPathComponent(".git/objects/object.bin"),
            bytes: 64 * 1024
        )
        try writeFile(movies.appendingPathComponent("large.bin"), bytes: 128 * 1024)
        try writeFile(hidden.appendingPathComponent("hidden.bin"), bytes: 256 * 1024)
        try writeFile(
            roots.home.appendingPathComponent("Library/ignored.bin"),
            bytes: 512 * 1024
        )

        let cacheApp = roots.caches.appendingPathComponent("Example.app", isDirectory: true)
        try createDirectory(cacheApp.appendingPathComponent("nested", isDirectory: true))
        try writeFile(cacheApp.appendingPathComponent("one.bin"), bytes: 16 * 1024)
        try writeFile(
            cacheApp.appendingPathComponent("nested/two.bin"),
            bytes: 48 * 1024
        )
        try writeFile(roots.caches.appendingPathComponent("single.tmp"), bytes: 4 * 1024)

        let tempGroup = roots.temporary.appendingPathComponent("session", isDirectory: true)
        try createDirectory(tempGroup)
        try writeFile(tempGroup.appendingPathComponent("temporary.bin"), bytes: 24 * 1024)

        let outside = fixtureRoot.appendingPathComponent("outside", isDirectory: true)
        try createDirectory(outside)
        try writeFile(outside.appendingPathComponent("outside.bin"), bytes: 1024 * 1024)
        try fileManager.createSymbolicLink(
            at: roots.home.appendingPathComponent("outside-link", isDirectory: true),
            withDestinationURL: outside
        )

        let service = DiskCleanupService(
            homeDirectory: roots.home,
            temporaryDirectory: roots.temporary,
            cachesDirectory: roots.caches,
            progressStride: 1,
            progressInterval: 0,
            trashMover: { _ in }
        )

        let largest = try service.scan(category: .largestFiles, largestFileLimit: 2)
        check(largest.items.count == 2, "limits largest-file results")
        check(
            largest.items.map(\.name) == ["large.bin", "medium.bin"],
            "sorts individual files by descending space used"
        )
        check(
            largest.items.allSatisfy { !$0.url.path.contains("/Library/") },
            "excludes Library from the home file scan"
        )
        check(
            largest.items.allSatisfy { !$0.url.path.contains(".hidden") },
            "excludes hidden home files"
        )
        check(
            largest.items.allSatisfy { !$0.url.path.contains("outside.bin") },
            "does not traverse symbolic links"
        )

        let caches = try service.scan(category: .caches)
        check(caches.items.first?.name == "Example.app", "sorts cache groups by size")
        check(caches.items.first?.fileCount == 2, "counts nested files in cache groups")
        check(
            caches.items.first?.sizeBytes ?? 0 > caches.items.last?.sizeBytes ?? 0,
            "aggregates package descendants"
        )

        let temporary = try service.scan(category: .temporary)
        check(temporary.items.map(\.name) == ["session"], "lists temporary groups")
        check(temporary.items.first?.fileCount == 1, "aggregates temporary files")

        let folders = try service.scan(category: .largeFolders)
        check(
            folders.items.map(\.name).contains("Movies"),
            "lists large home folders"
        )
        check(
            !folders.items.map(\.name).contains("Library"),
            "hides the system-managed Library folder"
        )
        check(
            folders.items.first(where: { $0.name == "Downloads" })?.protectionReason != nil,
            "protects standard home anchor folders"
        )
        check(
            folders.items.first(where: { $0.name == "Downloads" })?.fileCount == 3,
            "counts hidden descendants in a visible folder's cleanup size"
        )
    }

    private mutating func checkCancellation(in fixtureRoot: URL) throws {
        let roots = try makeRoots(in: fixtureRoot.appendingPathComponent("cancel", isDirectory: true))
        let files = roots.home.appendingPathComponent("Files", isDirectory: true)
        try createDirectory(files)
        for index in 0..<20 {
            try writeFile(
                files.appendingPathComponent("\(index).bin"),
                bytes: 4096 + index
            )
        }

        let token = DiskCleanupCancellationToken()
        let service = DiskCleanupService(
            homeDirectory: roots.home,
            temporaryDirectory: roots.temporary,
            cachesDirectory: roots.caches,
            progressStride: 1,
            progressInterval: 0,
            trashMover: { _ in }
        )

        do {
            _ = try service.scan(
                category: .largestFiles,
                cancellationToken: token,
                progress: { _ in token.cancel() }
            )
            fail("cancels an in-flight scan")
        } catch DiskCleanupError.cancelled {
            check(true, "cancels an in-flight scan")
        } catch {
            fail("cancels an in-flight scan: \(error.localizedDescription)")
        }

        let alreadyCancelledToken = DiskCleanupCancellationToken()
        alreadyCancelledToken.cancel()
        do {
            _ = try service.scan(
                category: .caches,
                cancellationToken: alreadyCancelledToken
            )
            fail("cancels before listing directory contents")
        } catch DiskCleanupError.cancelled {
            check(true, "cancels before listing directory contents")
        } catch {
            fail("cancels before listing directory contents: \(error.localizedDescription)")
        }
    }

    private mutating func checkIncompleteFolderProtection(in fixtureRoot: URL) throws {
        let roots = try makeRoots(in: fixtureRoot.appendingPathComponent("incomplete", isDirectory: true))
        let readable = roots.caches.appendingPathComponent("readable", isDirectory: true)
        let restricted = roots.caches.appendingPathComponent("restricted", isDirectory: true)
        try createDirectory(readable)
        try createDirectory(restricted)
        try writeFile(readable.appendingPathComponent("one.bin"), bytes: 4096)
        try writeFile(restricted.appendingPathComponent("hidden.bin"), bytes: 8192)

        try fileManager.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: restricted.path
        )
        defer {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: restricted.path
            )
        }

        let service = DiskCleanupService(
            homeDirectory: roots.home,
            temporaryDirectory: roots.temporary,
            cachesDirectory: roots.caches,
            trashMover: { _ in }
        )
        let result = try service.scan(category: .caches)
        guard let item = result.items.first(where: { $0.name == "restricted" }) else {
            fail("keeps unreadable top-level folders visible")
            return
        }
        check(
            item.protectionReason != nil,
            "protects folders whose size scan is incomplete"
        )
    }

    private mutating func checkTrashSafety(in fixtureRoot: URL) throws {
        let roots = try makeRoots(in: fixtureRoot.appendingPathComponent("trash", isDirectory: true))
        let downloads = roots.home.appendingPathComponent("Downloads", isDirectory: true)
        try createDirectory(downloads)
        let validURL = downloads.appendingPathComponent("valid.bin")
        try writeFile(validURL, bytes: 8192)
        let protectedURL = downloads.appendingPathComponent("protected.bin")
        try writeFile(protectedURL, bytes: 8192)
        let normalizedURL = downloads.appendingPathComponent("normalized.bin")
        try writeFile(normalizedURL, bytes: 8192)
        let nonStandardURL = URL(
            fileURLWithPath: downloads.appendingPathComponent("nested/../normalized.bin").path
        )

        let outsideURL = fixtureRoot.appendingPathComponent("outside-trash.bin")
        try writeFile(outsideURL, bytes: 8192)

        let symlinkURL = downloads.appendingPathComponent("linked.bin")
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideURL)

        var movedPaths: [String] = []
        let service = DiskCleanupService(
            homeDirectory: roots.home,
            temporaryDirectory: roots.temporary,
            cachesDirectory: roots.caches,
            trashMover: { movedPaths.append($0.standardizedFileURL.path) }
        )

        let validItem = item(validURL, kind: .file)
        let rootItem = item(roots.home, kind: .directory)
        let anchorItem = item(downloads, kind: .directory)
        let outsideItem = item(outsideURL, kind: .file)
        let symlinkItem = item(symlinkURL, kind: .file)
        let incompleteItem = DiskCleanupItem(
            url: protectedURL,
            name: protectedURL.lastPathComponent,
            kind: .file,
            sizeBytes: 8192,
            fileCount: 1,
            modificationDate: nil,
            protectionReason: "Incomplete scan"
        )
        let nonStandardItem = item(nonStandardURL, kind: .file)
        let result = service.moveToTrash(
            [
                incompleteItem,
                validItem,
                nonStandardItem,
                rootItem,
                anchorItem,
                outsideItem,
                symlinkItem
            ],
            category: .largestFiles
        )

        check(
            result.movedItems == [validItem, nonStandardItem],
            "moves only validated items"
        )
        check(
            movedPaths == [
                validURL.standardizedFileURL.path,
                normalizedURL.standardizedFileURL.path
            ],
            "uses standardized URLs with the injected Trash mover"
        )
        check(result.failures.count == 5, "reports every rejected Trash operation")

        let cacheURL = roots.caches.appendingPathComponent("safe-cache", isDirectory: true)
        try createDirectory(cacheURL)
        let cacheItem = item(cacheURL, kind: .directory)
        let cacheResult = service.moveToTrash([cacheItem], category: .caches)
        check(cacheResult.movedItems == [cacheItem], "allows cache children to move to Trash")
    }

    private func makeRoots(in root: URL) throws -> (home: URL, temporary: URL, caches: URL) {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        try createDirectory(home)
        try createDirectory(temporary)
        try createDirectory(caches)
        return (home, temporary, caches)
    }

    private func createDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    private func writeFile(_ url: URL, bytes: Int) throws {
        try createDirectory(url.deletingLastPathComponent())
        try Data(repeating: UInt8(bytes % 251), count: bytes).write(to: url)
    }

    private func item(_ url: URL, kind: DiskCleanupItemKind) -> DiskCleanupItem {
        DiskCleanupItem(
            url: url,
            name: url.lastPathComponent,
            kind: kind,
            sizeBytes: 8192,
            fileCount: kind == .file ? 1 : 0,
            modificationDate: nil,
            protectionReason: nil
        )
    }

    private mutating func check(_ condition: Bool, _ name: String) {
        if !condition { fail(name) }
    }

    private mutating func fail(_ message: String) {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

var runner = CheckRunner()
exit(runner.run())
