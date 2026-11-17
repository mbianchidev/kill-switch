import DiskCleanupCore
import Foundation
import TableQueryCore

struct CheckRunner {
    private var failures = 0
    private let fileManager = FileManager.default

    mutating func run() -> Int32 {
        checkTableQueries()
        checkFolderSizeThresholds()
        checkFolderSizeAlertPolicy()
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
            checkScanDelta()
            try checkCancellation(in: fixtureRoot)
            try checkParallelScanning(in: fixtureRoot)
            try checkParallelCancellation(in: fixtureRoot)
            try checkChangedFolderProtection(in: fixtureRoot)
            try checkIncompleteFolderProtection(in: fixtureRoot)
            try checkTrashSafety(in: fixtureRoot)
            try checkFolderSizeWatchList(in: fixtureRoot)
            try checkFolderSizeMeasurement(in: fixtureRoot)
            try checkFolderSizeStore()
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

    private mutating func checkFolderSizeThresholds() {
        let gigabyte = FolderSizeUnit.gigabytes.bytes
        check((try? FolderSizeThreshold.bytes(from: " 10 ", unit: .gigabytes)) == 10 * gigabyte, "parses whole thresholds in binary units")
        check((try? FolderSizeThreshold.bytes(from: "1,5", unit: .gigabytes)) == gigabyte + gigabyte / 2, "accepts a comma decimal separator")
        check((try? FolderSizeThreshold.bytes(from: "1.25", unit: .gigabytes)) == gigabyte + gigabyte / 4, "accepts two decimals")
        for invalid in ["", "abc", "-1", "0", "1e3", "1.2.3", "10GB", ".", "1,500", "1.500"] {
            check((try? FolderSizeThreshold.bytes(from: invalid, unit: .gigabytes)) == nil, "rejects malformed threshold \(invalid)")
        }
        check((try? FolderSizeThreshold.bytes(from: "0.5", unit: .megabytes)) == nil, "rejects thresholds below 1 MB")
        check((try? FolderSizeThreshold.bytes(from: "1025", unit: .terabytes)) == nil, "rejects thresholds above 1,024 TB")
        let tenGB = FolderSizeThreshold.components(for: 10 * gigabyte)
        let oneAndHalf = FolderSizeThreshold.components(for: 1_536 * FolderSizeUnit.megabytes.bytes)
        check(tenGB.value == "10" && tenGB.unit == .gigabytes && oneAndHalf.value == "1.5" && oneAndHalf.unit == .gigabytes,
              "displays thresholds in the largest whole unit")
        for (text, unit) in [("2000", FolderSizeUnit.gigabytes), ("1500", .megabytes), ("1.95", .terabytes), ("1023.99", .megabytes)] {
            guard let bytes = try? FolderSizeThreshold.bytes(from: text, unit: unit) else {
                fail("parses round-trip threshold \(text) \(unit.rawValue)")
                continue
            }
            let shown = FolderSizeThreshold.components(for: bytes)
            check((try? FolderSizeThreshold.bytes(from: shown.value, unit: shown.unit)) == bytes,
                  "redisplayed threshold \(text) \(unit.rawValue) parses back without changing")
        }
    }

    private mutating func checkFolderSizeAlertPolicy() {
        let threshold: UInt64 = 1_000 * FolderSizeUnit.megabytes.bytes
        func measurement(_ size: UInt64, complete: Bool = true) -> FolderSizeMeasurement {
            FolderSizeMeasurement(
                path: "/tmp/synthetic", sizeBytes: size, fileCount: 1,
                permissionDeniedCount: complete ? 0 : 1, unreadableItemCount: 0,
                measuredAt: Date(timeIntervalSince1970: 100)
            )
        }
        let reached = FolderSizeAlertState.reached(since: Date(timeIntervalSince1970: 100))
        let first = FolderSizeAlertPolicy.evaluate(.armed, measurement: measurement(threshold), thresholdBytes: threshold)
        check(first.shouldAlert && first.state == reached, "alerts when a folder reaches its threshold")
        check(!FolderSizeAlertPolicy.evaluate(reached, measurement: measurement(threshold * 2), thresholdBytes: threshold).shouldAlert,
              "does not repeat an alert while the folder stays above its threshold")
        check(FolderSizeAlertPolicy.evaluate(.armed, measurement: measurement(threshold, complete: false), thresholdBytes: threshold).shouldAlert,
              "a partial size at the threshold is a valid lower bound for alerting")
        check(FolderSizeAlertPolicy.evaluate(reached, measurement: measurement(threshold - threshold / 40), thresholdBytes: threshold).state == reached,
              "stays reached while hovering within 5% below the threshold")
        check(FolderSizeAlertPolicy.evaluate(reached, measurement: measurement(threshold / 2, complete: false), thresholdBytes: threshold).state == reached,
              "a partial size never proves a folder shrank")
        check(FolderSizeAlertPolicy.evaluate(reached, measurement: measurement(threshold / 2), thresholdBytes: threshold).state == .armed,
              "re-arms after a complete size falls clearly below the threshold")
    }

    private mutating func checkTableQueries() {
        let file = DiskCleanupItem(
            url: URL(fileURLWithPath: "/tmp/example-file"), name: "Example file", kind: .file,
            sizeBytes: 2_048, fileCount: 1, modificationDate: nil, protectionReason: nil
        )
        let folder = DiskCleanupItem(
            url: URL(fileURLWithPath: "/tmp/example-folder"), name: "Example folder", kind: .directory,
            sizeBytes: 1_048_576, fileCount: 20, modificationDate: Date(timeIntervalSince1970: 0),
            protectionReason: "Synthetic protected root"
        )
        let rows = [folder, file]
        let query = TableQuery(search: "size > 1KB type = File removable = yes", fields: DiskCleanupTableFields.all)
        check(query.error == nil && query.filter(rows) == [file], "disk search combines size, type, and removable filters")
        check(
            TableQuery(search: "contents >= 10 type = Folder", fields: DiskCleanupTableFields.all).filter(rows) == [folder]
                && !folder.canTrash,
            "filtering disk rows never removes their protected-file restriction"
        )
        check(
            TableComparator(field: DiskCleanupTableFields.size).sorted(rows, identity: \.id) == [file, folder],
            "disk rows sort by numeric bytes rather than formatted size"
        )
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

    private mutating func checkParallelScanning(in fixtureRoot: URL) throws {
        let roots = try makeRoots(in: fixtureRoot.appendingPathComponent("parallel", isDirectory: true))
        let projects = roots.home.appendingPathComponent("Projects", isDirectory: true)
        for project in 0..<6 {
            for module in 0..<4 {
                for leaf in 0..<3 {
                    let folder = projects.appendingPathComponent(
                        "p\(project)/m\(module)/d\(leaf)",
                        isDirectory: true
                    )
                    try writeFile(
                        folder.appendingPathComponent("data.bin"),
                        bytes: 1024 * (project * 12 + module * 3 + leaf + 1)
                    )
                    try writeFile(folder.appendingPathComponent(".hidden.bin"), bytes: 2048)
                }
            }
        }
        let package = roots.home.appendingPathComponent("Tool.app", isDirectory: true)
        try writeFile(package.appendingPathComponent("Contents/payload.bin"), bytes: 900 * 1024)
        try writeFile(roots.home.appendingPathComponent("Library/ignored.bin"), bytes: 800 * 1024)
        try fileManager.createSymbolicLink(
            at: projects.appendingPathComponent("p0/linked", isDirectory: true),
            withDestinationURL: package
        )
        for group in 0..<5 {
            try writeFile(
                roots.caches.appendingPathComponent("group\(group)/a/b/c/cache.bin"),
                bytes: 4096 * (group + 1)
            )
            try writeFile(
                roots.temporary.appendingPathComponent("session\(group)/x/y/temp.bin"),
                bytes: 2048 * (group + 1)
            )
        }

        func makeService(concurrency: Int) -> DiskCleanupService {
            DiskCleanupService(
                homeDirectory: roots.home,
                temporaryDirectory: roots.temporary,
                cachesDirectory: roots.caches,
                progressStride: 1,
                progressInterval: 0,
                scanConcurrency: concurrency,
                trashMover: { _ in }
            )
        }
        let serial = makeService(concurrency: 1)
        let parallel = makeService(concurrency: 8)

        for category in DiskCleanupCategory.allCases {
            var progressCounts: [Int] = []
            let serialResult = try serial.scan(category: category, largestFileLimit: 10)
            let parallelResult = try parallel.scan(
                category: category,
                largestFileLimit: 10,
                progress: { progressCounts.append($0.scannedEntryCount) }
            )
            check(
                parallelResult == serialResult,
                "parallel \(category) scan matches a single-worker scan"
            )
            check(
                progressCounts == progressCounts.sorted()
                    && progressCounts.last == parallelResult.scannedEntryCount,
                "parallel \(category) progress stays monotonic"
            )
        }

        let largest = try parallel.scan(category: .largestFiles, largestFileLimit: 3)
        check(
            largest.items.map(\.name) == ["data.bin", "data.bin", "data.bin"]
                && largest.items.first?.sizeBytes ?? 0 >= 72 * 1024,
            "parallel largest-file scan skips packages, Library, and symbolic links"
        )
        let folders = try parallel.scan(category: .largeFolders)
        check(
            folders.items.first(where: { $0.name == "Projects" })?.fileCount == 144,
            "parallel folder scan counts every nested and hidden descendant once"
        )
    }

    private mutating func checkParallelCancellation(in fixtureRoot: URL) throws {
        let roots = try makeRoots(in: fixtureRoot.appendingPathComponent("parallel-cancel", isDirectory: true))
        var directoryCount = 1
        for group in 0..<24 {
            for branch in 0..<4 {
                try writeFile(
                    roots.caches.appendingPathComponent("group\(group)/b\(branch)/leaf/cache.bin"),
                    bytes: 1024
                )
            }
            directoryCount += 9
        }

        let token = DiskCleanupCancellationToken()
        let barrier = NSCondition()
        let rootPath = roots.caches.standardizedFileURL.path
        var listingCount = 0
        var descendantReads = 0
        var barrierReached = false
        var barrierTimedOut = false
        let hooked = ListingHookFileManager()
        hooked.willList = { url in
            barrier.lock()
            defer { barrier.unlock() }
            listingCount += 1
            guard url.standardizedFileURL.path != rootPath else { return }
            descendantReads += 1
            if descendantReads == 2 {
                barrierReached = true
                token.cancel()
                barrier.broadcast()
                return
            }
            // Hold the first descendant read until a second worker is reading too.
            let deadline = Date().addingTimeInterval(5)
            while !barrierReached, barrier.wait(until: deadline) {}
            if !barrierReached { barrierTimedOut = true }
        }
        let service = DiskCleanupService(
            fileManager: hooked,
            homeDirectory: roots.home,
            temporaryDirectory: roots.temporary,
            cachesDirectory: roots.caches,
            scanConcurrency: 8,
            trashMover: { _ in }
        )

        do {
            _ = try service.scan(category: .caches, cancellationToken: token)
            fail("cancels a parallel scan while descendant folders are being read")
        } catch DiskCleanupError.cancelled {
            check(true, "cancels a parallel scan while descendant folders are being read")
        } catch {
            fail("cancels a parallel scan while descendant folders are being read: \(error.localizedDescription)")
        }
        barrier.lock()
        let concurrent = barrierReached && !barrierTimedOut
        let listed = listingCount
        barrier.unlock()
        check(concurrent, "parallel scan reads two descendant folders at the same time")
        check(
            listed < directoryCount,
            "parallel workers stop listing after cancellation (\(listed) of \(directoryCount) folders)"
        )
    }

    private mutating func checkChangedFolderProtection(in fixtureRoot: URL) throws {
        let roots = try makeRoots(in: fixtureRoot.appendingPathComponent("changed", isDirectory: true))
        let middle = roots.caches.appendingPathComponent("swapped/middle", isDirectory: true)
        let victim = middle.appendingPathComponent("victim", isDirectory: true)
        try writeFile(victim.appendingPathComponent("inside.bin"), bytes: 4096)
        try writeFile(roots.caches.appendingPathComponent("steady/cache.bin"), bytes: 4096)
        let outside = fixtureRoot.appendingPathComponent("changed-outside", isDirectory: true)
        try writeFile(outside.appendingPathComponent("victim/outside.bin"), bytes: 1024 * 1024)
        let moved = fixtureRoot.appendingPathComponent("changed-moved", isDirectory: true)

        let victimPath = victim.standardizedFileURL.path
        var swapped = false
        var swapError: Error?
        let swapping = ListingHookFileManager()
        // Replacing the queued folder's parent makes the same path resolve into another tree.
        swapping.willList = { url in
            guard url.standardizedFileURL.path == victimPath, !swapped else { return }
            swapped = true
            do {
                try FileManager.default.moveItem(at: middle, to: moved)
                try FileManager.default.createSymbolicLink(at: middle, withDestinationURL: outside)
            } catch {
                swapError = error
            }
        }
        let result = try DiskCleanupService(
            fileManager: swapping,
            homeDirectory: roots.home,
            temporaryDirectory: roots.temporary,
            cachesDirectory: roots.caches,
            scanConcurrency: 4,
            trashMover: { _ in }
        ).scan(category: .caches)
        let changed = result.items.first { $0.name == "swapped" }
        check(swapped && swapError == nil, "replaces a queued folder's parent with a symbolic link during the scan")
        check(
            changed?.protectionReason != nil && changed?.sizeBytes ?? .max < 1024 * 1024,
            "protects a folder whose queued subfolder resolves elsewhere without counting the other tree"
        )
        check(
            result.items.first { $0.name == "steady" }?.protectionReason == nil,
            "keeps unchanged sibling folders removable"
        )

        let failingRoot = ListingHookFileManager()
        let rootPath = roots.caches.standardizedFileURL.path
        failingRoot.willList = { url in
            if url.standardizedFileURL.path == rootPath {
                throw CocoaError(.fileReadUnknown)
            }
        }
        let rootFailure = try DiskCleanupService(
            fileManager: failingRoot,
            homeDirectory: roots.home,
            temporaryDirectory: roots.temporary,
            cachesDirectory: roots.caches,
            trashMover: { _ in }
        ).scan(category: .caches)
        check(
            !rootFailure.items.isEmpty && rootFailure.items.allSatisfy { $0.protectionReason != nil },
            "protects every listed folder when the root size listing fails"
        )
    }

    private mutating func checkScanDelta() {
        let root = URL(fileURLWithPath: "/tmp/disk-cleanup-delta", isDirectory: true)
        let removed = item(root.appendingPathComponent("removed.bin"), kind: .file)
        let unchanged = item(root.appendingPathComponent("unchanged.bin"), kind: .file)
        let updatedURL = root.appendingPathComponent("updated.bin")
        let previousUpdated = item(updatedURL, kind: .file)
        let currentUpdated = DiskCleanupItem(
            url: updatedURL,
            name: updatedURL.lastPathComponent,
            kind: .file,
            sizeBytes: 16_384,
            fileCount: 1,
            modificationDate: Date(timeIntervalSince1970: 2),
            protectionReason: nil
        )
        let added = item(root.appendingPathComponent("added.bin"), kind: .file)
        let previous = [removed, previousUpdated, unchanged]
        let current = [currentUpdated, added, unchanged]

        let delta = DiskCleanupScanDelta(previousItems: previous, currentItems: current)
        check(delta.addedItems == [added], "identifies added scan items")
        check(delta.updatedItems == [currentUpdated], "identifies updated scan items")
        check(delta.removedItems == [removed], "identifies removed scan items")
        check(delta.changeCount == 3, "counts every differential scan change")
        check(
            delta.applying(to: previous) == current,
            "applies scan changes in the current scan order"
        )

        let unchangedDelta = DiskCleanupScanDelta(
            previousItems: current,
            currentItems: current
        )
        check(unchangedDelta.isEmpty, "reports an empty differential scan")
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

    private mutating func checkFolderSizeWatchList(in fixtureRoot: URL) throws {
        let base = fixtureRoot.appendingPathComponent("folder-watch-list", isDirectory: true)
        let folder = base.appendingPathComponent("watched", isDirectory: true)
        let alias = base.appendingPathComponent("alias", isDirectory: true)
        let file = base.appendingPathComponent("file.bin")
        try createDirectory(folder)
        try writeFile(file, bytes: 1_024)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: folder)

        var list = FolderSizeWatchList()
        let watch = try list.add(folder: folder)
        check(watch.thresholdBytes == FolderSizeThreshold.defaultBytes && watch.isEnabled && watch.alertState == .armed,
              "new watches start enabled and armed with the default threshold")
        func rejects(_ url: URL, threshold: UInt64 = FolderSizeThreshold.defaultBytes, _ name: String) {
            var copy = list
            check((try? copy.add(folder: url, thresholdBytes: threshold)) == nil && copy == list, name)
        }
        rejects(alias, "rejects a link to an already watched folder")
        rejects(file, "rejects files")
        rejects(base.appendingPathComponent("missing", isDirectory: true), "rejects missing folders")
        rejects(base, threshold: 0, "rejects invalid thresholds")

        let threshold = FolderSizeThreshold.minimumBytes
        try list.setThreshold(threshold, for: watch.id)
        let large = FolderSizeMeasurement(
            path: watch.path, sizeBytes: threshold, fileCount: 1, permissionDeniedCount: 0,
            unreadableItemCount: 0, measuredAt: Date()
        )
        check(list.record(large, for: watch.id)?.thresholdBytes == threshold, "recording a size at the threshold returns an alert")
        check(list.record(large, for: watch.id) == nil, "a reached folder does not alert again")
        try list.setThreshold(threshold * 2, for: watch.id)
        check(list.watch(id: watch.id)?.alertState == .armed, "changing a threshold re-arms its alert")
        try list.setThreshold(threshold, for: watch.id)
        try list.setEnabled(false, for: watch.id)
        check(list.record(large, for: watch.id) == nil && list.watch(id: watch.id)?.alertState == .armed,
              "paused watches ignore late measurements")
        try list.setEnabled(true, for: watch.id)
        let otherFolder = FolderSizeMeasurement(
            path: base.path, sizeBytes: threshold, fileCount: 1, permissionDeniedCount: 0,
            unreadableItemCount: 0, measuredAt: Date()
        )
        check(list.record(otherFolder, for: watch.id) == nil, "ignores a measurement of a different folder")
        check(list.remove(id: watch.id)?.id == watch.id && list.record(large, for: watch.id) == nil && list.watches.isEmpty,
              "removed watches ignore late measurements")
    }

    private mutating func checkFolderSizeMeasurement(in fixtureRoot: URL) throws {
        let base = fixtureRoot.appendingPathComponent("folder-size", isDirectory: true)
        let root = base.appendingPathComponent("watched", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let counted = [
            root.appendingPathComponent("top.bin"),
            root.appendingPathComponent("nested/deeper/inner.bin"),
            root.appendingPathComponent(".hidden/secret.bin"),
            root.appendingPathComponent("Example.app/Contents/payload.bin"),
            root.appendingPathComponent("hard-original.bin")
        ]
        for (index, url) in counted.enumerated() {
            try writeFile(url, bytes: 4_096 * (index + 1))
        }
        try fileManager.linkItem(at: counted[4], to: root.appendingPathComponent("nested/hard-copy.bin"))
        try writeFile(outside.appendingPathComponent("large.bin"), bytes: 1_048_576)
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("file-link.bin"), withDestinationURL: outside.appendingPathComponent("large.bin"))
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("folder-link"), withDestinationURL: outside)
        let expected = try counted.reduce(UInt64(0)) { total, url in
            total + UInt64(try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
        }

        let measurer = FolderSizeMeasurer(workerCount: 4)
        let measurement = try measurer.measure(root)
        check(measurement.sizeBytes == expected && measurement.fileCount == counted.count && measurement.isComplete,
              "measures hidden and package files once per hard link without following links")

        let restricted = root.appendingPathComponent("restricted", isDirectory: true)
        try writeFile(restricted.appendingPathComponent("blocked.bin"), bytes: 8_192)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        let partial = try measurer.measure(root)
        check(!partial.isComplete && partial.permissionDeniedCount > 0 && partial.sizeBytes == expected,
              "reports unreadable subfolders as an incomplete lower bound")

        func error(measuring url: URL, token: DiskCleanupCancellationToken = DiskCleanupCancellationToken()) -> FolderSizeWatchError? {
            do {
                _ = try measurer.measure(url, cancellationToken: token)
                return nil
            } catch {
                return error as? FolderSizeWatchError
            }
        }
        check(error(measuring: restricted) == .permissionDenied(restricted.path), "an unreadable watched folder is an error, not zero bytes")
        let missing = base.appendingPathComponent("missing", isDirectory: true)
        check(error(measuring: missing) == .folderUnavailable(missing.path), "reports missing watched folders")
        check(error(measuring: counted[0]) == .notAFolder(counted[0].path), "refuses to measure files")
        let token = DiskCleanupCancellationToken()
        token.cancel()
        check(error(measuring: root, token: token) == .cancelled, "honors folder measurement cancellation")
    }

    private mutating func checkFolderSizeStore() throws {
        let suite = "DiskCleanupCoreChecks.folder-size-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("creates isolated folder alert preferences")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FolderSizeWatchStore(defaults: defaults)
        let allowed = [60, 300, FolderSizeWatchStore.defaultIntervalSeconds]
        check(try store.loadWatches().watches.isEmpty && store.intervalSeconds(allowed: allowed) == FolderSizeWatchStore.defaultIntervalSeconds,
              "starts with no watches and the default interval")
        store.setIntervalSeconds(300)
        check(store.intervalSeconds(allowed: allowed) == 300, "persists a supported check interval")
        store.setIntervalSeconds(42)
        check(store.intervalSeconds(allowed: allowed) == FolderSizeWatchStore.defaultIntervalSeconds, "ignores unsupported saved intervals")

        let list = FolderSizeWatchList([
            FolderSizeWatch(path: "/tmp/synthetic-a", thresholdBytes: FolderSizeThreshold.defaultBytes),
            FolderSizeWatch(path: "/tmp/synthetic-b", thresholdBytes: FolderSizeThreshold.minimumBytes, isEnabled: false,
                            alertState: .reached(since: Date(timeIntervalSince1970: 1_000)))
        ])
        try store.save(list)
        check(try store.loadWatches() == list, "round-trips watched folders and alert state")

        let corrupt = Data("not json".utf8)
        defaults.set(corrupt, forKey: "foldersize.watches")
        do {
            _ = try store.loadWatches()
            fail("reports unreadable saved watches")
        } catch {
            check(defaults.data(forKey: "foldersize.watches.unreadable") == corrupt && (try? store.loadWatches()) == FolderSizeWatchList(),
                  "backs up unreadable saved watches before resetting them")
        }
        let invalid = try JSONEncoder().encode([FolderSizeWatch(path: "/tmp/synthetic-invalid", thresholdBytes: 0)])
        defaults.set(invalid, forKey: "foldersize.watches")
        check((try? store.loadWatches()) == nil, "rejects saved watches with invalid thresholds")
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

/// Runs a synthetic hook before each directory listing so checks can pause, fail, or change folders.
final class ListingHookFileManager: FileManager {
    var willList: ((URL) throws -> Void)?

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        try willList?(url)
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

var runner = CheckRunner()
exit(runner.run())
