import Foundation

public final class DiskCleanupService {
    public typealias ProgressHandler = (DiskCleanupProgress) -> Void
    public typealias TrashMover = (URL) throws -> Void

    public let homeDirectory: URL
    public let temporaryDirectory: URL
    public let cachesDirectory: URL

    private let fileManager: FileManager
    private let trashMover: TrashMover
    private let progressStride: Int
    private let progressInterval: TimeInterval
    private let scanConcurrency: Int

    private let resourceKeys: Set<URLResourceKey> = [
        .contentModificationDateKey,
        .fileSizeKey,
        .isDirectoryKey,
        .isPackageKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isUbiquitousItemKey,
        .totalFileAllocatedSizeKey
    ]

    private let protectedHomeAnchorNames: Set<String> = [
        "Applications",
        "Desktop",
        "Documents",
        "Downloads",
        "Movies",
        "Music",
        "Pictures",
        "Public"
    ]

    public init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        temporaryDirectory: URL? = nil,
        cachesDirectory: URL? = nil,
        progressStride: Int = 512,
        progressInterval: TimeInterval = 0.15,
        scanConcurrency: Int? = nil,
        trashMover: TrashMover? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = (homeDirectory ?? fileManager.homeDirectoryForCurrentUser).standardizedFileURL
        self.temporaryDirectory = (temporaryDirectory ?? fileManager.temporaryDirectory).standardizedFileURL
        self.cachesDirectory = (
            cachesDirectory
                ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? self.homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true)
        ).standardizedFileURL
        self.progressStride = max(1, progressStride)
        self.progressInterval = max(0, progressInterval)
        self.scanConcurrency = max(1, scanConcurrency ?? Self.defaultScanConcurrency)
        self.trashMover = trashMover ?? { url in
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// Directory reads run in parallel up to the active CPU count; gains flatten beyond 16 workers.
    private static var defaultScanConcurrency: Int {
        min(max(1, ProcessInfo.processInfo.activeProcessorCount), 16)
    }

    public func rootURL(for category: DiskCleanupCategory) -> URL {
        switch category {
        case .largestFiles, .largeFolders:
            return homeDirectory
        case .temporary:
            return temporaryDirectory
        case .caches:
            return cachesDirectory
        }
    }

    public func scan(
        category: DiskCleanupCategory,
        directory: URL? = nil,
        largestFileLimit: Int = 200,
        cancellationToken: DiskCleanupCancellationToken = DiskCleanupCancellationToken(),
        progress: ProgressHandler? = nil
    ) throws -> DiskCleanupScanResult {
        switch category {
        case .largestFiles:
            return try scanLargestFiles(
                limit: max(1, largestFileLimit),
                cancellationToken: cancellationToken,
                progress: progress
            )
        case .temporary, .caches, .largeFolders:
            let root = try validatedScanDirectory(directory ?? rootURL(for: category), category: category)
            return try scanDirectory(
                root,
                category: category,
                cancellationToken: cancellationToken,
                progress: progress
            )
        }
    }

    public func moveToTrash(
        _ items: [DiskCleanupItem],
        category: DiskCleanupCategory
    ) -> DiskCleanupTrashResult {
        var movedItems: [DiskCleanupItem] = []
        var failures: [DiskCleanupTrashFailure] = []
        var seenPaths: Set<String> = []

        for item in items {
            let candidate = item.url.standardizedFileURL
            let path = candidate.path
            guard seenPaths.insert(path).inserted else { continue }

            do {
                if let reason = item.protectionReason {
                    throw DiskCleanupError.unsafeTrashLocation(path, reason)
                }
                try validateTrashLocation(candidate, category: category)
                try trashMover(candidate)
                movedItems.append(item)
            } catch {
                failures.append(
                    DiskCleanupTrashFailure(item: item, message: error.localizedDescription)
                )
            }
        }

        return DiskCleanupTrashResult(movedItems: movedItems, failures: failures)
    }

    private func scanLargestFiles(
        limit: Int,
        cancellationToken: DiskCleanupCancellationToken,
        progress: ProgressHandler?
    ) throws -> DiskCleanupScanResult {
        guard fileManager.fileExists(atPath: homeDirectory.path) else {
            throw DiskCleanupError.unavailableRoot(homeDirectory.path)
        }
        try checkCancellation(cancellationToken)

        let walk = ParallelDirectoryWalk<Int, LargestFilesPartial>(
            fileManager: fileManager,
            resourceKeys: resourceKeys,
            options: [.skipsHiddenFiles],
            workerCount: scanConcurrency,
            progressStride: progressStride,
            progressInterval: progressInterval,
            cancellationToken: cancellationToken,
            progress: progress
        )
        let outcome = walk.run(
            root: homeDirectory,
            context: 0,
            makePartial: { LargestFilesPartial(largest: BoundedLargestItems(limit: limit)) },
            listingFailed: { partial, _, _, error in
                partial.counters.record(error)
            },
            visit: { partial, url, depth in
                // Library and .Trash are direct children of home, so excluding them there skips their subtrees.
                if depth == 0, shouldExcludeHomeSubtree(url) {
                    return nil
                }

                let values: URLResourceValues
                do {
                    values = try url.resourceValues(forKeys: resourceKeys)
                } catch {
                    partial.counters.record(error)
                    return nil
                }
                if values.isSymbolicLink == true {
                    partial.counters.skippedItemCount += 1
                    return nil
                }
                if values.isUbiquitousItem == true {
                    partial.counters.excludedCloudItemCount += 1
                    return nil
                }
                if values.isDirectory == true {
                    return values.isPackage == true ? nil : depth + 1
                }
                guard values.isRegularFile == true else { return nil }

                let size = Self.diskSize(values)
                guard size > 0, partial.largest.mightAccept(sizeBytes: size) else { return nil }
                partial.largest.insert(
                    DiskCleanupItem(
                        url: url.standardizedFileURL,
                        name: url.lastPathComponent,
                        kind: .file,
                        sizeBytes: size,
                        fileCount: 1,
                        modificationDate: values.contentModificationDate,
                        protectionReason: protectionReason(
                            for: url,
                            category: .largestFiles,
                            isDirectory: false,
                            isSymbolicLink: false,
                            isUbiquitous: false
                        )
                    )
                )
                return nil
            }
        )

        try checkCancellation(cancellationToken)
        progress?(DiskCleanupProgress(
            scannedEntryCount: outcome.scannedEntryCount,
            currentURL: homeDirectory
        ))

        var largest = BoundedLargestItems(limit: limit)
        var counters = DiskScanCounters()
        for partial in outcome.partials {
            largest.merge(partial.largest)
            counters.add(partial.counters)
        }
        return DiskCleanupScanResult(
            category: .largestFiles,
            rootURL: homeDirectory,
            items: largest.sortedItems,
            scannedEntryCount: outcome.scannedEntryCount,
            skippedItemCount: counters.skippedItemCount,
            permissionDeniedCount: counters.permissionDeniedCount,
            excludedCloudItemCount: counters.excludedCloudItemCount
        )
    }

    private func scanDirectory(
        _ root: URL,
        category: DiskCleanupCategory,
        cancellationToken: DiskCleanupCancellationToken,
        progress: ProgressHandler?
    ) throws -> DiskCleanupScanResult {
        try checkCancellation(cancellationToken)
        var counters = DiskScanCounters()
        var incompleteAccumulatorPaths: Set<String> = []

        var accumulators: [DirectoryAccumulator] = []
        var accumulatorIndexByPath: [String: Int] = [:]

        guard let directEnumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { url, error in
                if let path = self.directChildPath(containing: url, under: root) {
                    incompleteAccumulatorPaths.insert(path)
                }
                counters.record(error)
                return true
            }
        ) else {
            throw DiskCleanupError.unreadableDirectory(
                root.path,
                "File enumeration could not start."
            )
        }

        while let rawURL = directEnumerator.nextObject() {
            guard let url = rawURL as? URL else {
                counters.skippedItemCount += 1
                continue
            }
            try checkCancellation(cancellationToken)
            if category == .largeFolders && shouldExcludeHomeSubtree(url) {
                continue
            }

            do {
                let values = try url.resourceValues(forKeys: resourceKeys)
                if values.isSymbolicLink == true {
                    counters.skippedItemCount += 1
                    continue
                }
                if values.isUbiquitousItem == true {
                    counters.excludedCloudItemCount += 1
                    continue
                }

                let kind: DiskCleanupItemKind
                if values.isDirectory == true {
                    kind = values.isPackage == true ? .package : .directory
                } else if values.isRegularFile == true {
                    kind = .file
                } else {
                    counters.skippedItemCount += 1
                    continue
                }

                let name = url.lastPathComponent
                accumulatorIndexByPath[url.standardizedFileURL.path] = accumulators.count
                accumulators.append(
                    DirectoryAccumulator(
                        url: url.standardizedFileURL,
                        name: name,
                        kind: kind,
                        modificationDate: values.contentModificationDate,
                        protectionReason: protectionReason(
                            for: url,
                            category: category,
                            isDirectory: kind != .file,
                            isSymbolicLink: false,
                            isUbiquitous: false
                        )
                    )
                )
            } catch {
                counters.record(error)
            }
        }

        let indexByPath = accumulatorIndexByPath
        let accumulatorCount = accumulators.count
        let walk = ParallelDirectoryWalk<DirectoryScanContext, DirectoryScanPartial>(
            fileManager: fileManager,
            resourceKeys: resourceKeys,
            // Hidden descendants count because moving the visible parent to Trash removes them too.
            options: [],
            workerCount: scanConcurrency,
            progressStride: progressStride,
            progressInterval: progressInterval,
            cancellationToken: cancellationToken,
            progress: progress
        )
        let outcome = walk.run(
            root: root,
            context: .root,
            makePartial: { DirectoryScanPartial(accumulatorCount: accumulatorCount) },
            listingFailed: { partial, _, context, error in
                switch context {
                case .root:
                    // Without the root listing no folder size is known.
                    partial.incompleteIndices.formUnion(0..<accumulatorCount)
                case .accumulator(let index):
                    partial.incompleteIndices.insert(index)
                }
                partial.counters.record(error)
            },
            visit: { partial, url, context in
                let index: Int
                switch context {
                case .root:
                    guard let topLevelIndex = indexByPath[url.standardizedFileURL.path] else {
                        return nil
                    }
                    index = topLevelIndex
                case .accumulator(let parentIndex):
                    index = parentIndex
                }

                let values: URLResourceValues
                do {
                    values = try url.resourceValues(forKeys: resourceKeys)
                } catch {
                    partial.counters.record(error)
                    // An entry of unknown type may be an unmeasured folder.
                    partial.incompleteIndices.insert(index)
                    return nil
                }
                if values.isSymbolicLink == true {
                    partial.counters.skippedItemCount += 1
                    return nil
                }
                if values.isUbiquitousItem == true {
                    partial.counters.excludedCloudItemCount += 1
                    return nil
                }
                if values.isDirectory == true {
                    return .accumulator(index)
                }
                guard values.isRegularFile == true else { return nil }

                partial.sizes[index] += Self.diskSize(values)
                partial.fileCounts[index] += 1
                return nil
            }
        )

        try checkCancellation(cancellationToken)
        progress?(DiskCleanupProgress(
            scannedEntryCount: outcome.scannedEntryCount,
            currentURL: root
        ))

        var incompleteIndices: Set<Int> = []
        for partial in outcome.partials {
            for index in accumulators.indices {
                accumulators[index].sizeBytes += partial.sizes[index]
                accumulators[index].fileCount += partial.fileCounts[index]
            }
            incompleteIndices.formUnion(partial.incompleteIndices)
            counters.add(partial.counters)
        }

        let items = accumulators.enumerated().map { index, accumulator in
            accumulator.item(
                scanIncomplete: incompleteIndices.contains(index)
                    || incompleteAccumulatorPaths.contains(accumulator.url.standardizedFileURL.path)
            )
        }.sorted(by: Self.sortLargestFirst)
        return DiskCleanupScanResult(
            category: category,
            rootURL: root,
            items: items,
            scannedEntryCount: outcome.scannedEntryCount,
            skippedItemCount: counters.skippedItemCount,
            permissionDeniedCount: counters.permissionDeniedCount,
            excludedCloudItemCount: counters.excludedCloudItemCount
        )
    }

    private func validatedScanDirectory(
        _ directory: URL,
        category: DiskCleanupCategory
    ) throws -> URL {
        let candidate = directory.standardizedFileURL
        let categoryRoot = rootURL(for: category)
        guard Self.isDescendantOrEqual(candidate, of: categoryRoot) else {
            throw DiskCleanupError.invalidScanLocation(candidate.path)
        }
        if category == .largeFolders, shouldExcludeHomeSubtree(candidate) {
            throw DiskCleanupError.invalidScanLocation(candidate.path)
        }
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw DiskCleanupError.unavailableRoot(candidate.path)
        }
        if isSymbolicLink(candidate) {
            throw DiskCleanupError.invalidScanLocation(candidate.path)
        }

        do {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey])
            guard values.isDirectory == true, values.isUbiquitousItem != true else {
                throw DiskCleanupError.invalidScanLocation(candidate.path)
            }
        } catch let error as DiskCleanupError {
            throw error
        } catch {
            throw DiskCleanupError.unreadableDirectory(candidate.path, error.localizedDescription)
        }
        return candidate
    }

    private func validateTrashLocation(
        _ url: URL,
        category: DiskCleanupCategory
    ) throws {
        let candidate = url.standardizedFileURL
        let root = rootURL(for: category)
        guard Self.isDescendantOrEqual(candidate, of: root), candidate != root else {
            throw DiskCleanupError.unsafeTrashLocation(
                candidate.path,
                "the selected cleanup root is protected"
            )
        }

        let components = relativeComponents(of: candidate, from: root) ?? []
        guard !components.isEmpty else {
            throw DiskCleanupError.unsafeTrashLocation(
                candidate.path,
                "the selected cleanup root is protected"
            )
        }

        var current = root
        for component in components {
            current.appendPathComponent(component)
            if isSymbolicLink(current) {
                throw DiskCleanupError.unsafeTrashLocation(
                    candidate.path,
                    "symbolic links and paths through symbolic links are not deleted"
                )
            }
            do {
                let values = try current.resourceValues(forKeys: [.isUbiquitousItemKey])
                if values.isUbiquitousItem == true {
                    throw DiskCleanupError.unsafeTrashLocation(
                        candidate.path,
                        "iCloud-synced items are excluded to avoid deleting them from other devices"
                    )
                }
            } catch let error as DiskCleanupError {
                throw error
            } catch {
                throw DiskCleanupError.unsafeTrashLocation(
                    candidate.path,
                    "the item could not be revalidated: \(error.localizedDescription)"
                )
            }
        }

        do {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey])
            if let reason = protectionReason(
                for: candidate,
                category: category,
                isDirectory: values.isDirectory == true,
                isSymbolicLink: false,
                isUbiquitous: false
            ) {
                throw DiskCleanupError.unsafeTrashLocation(candidate.path, reason)
            }
        } catch let error as DiskCleanupError {
            throw error
        } catch {
            throw DiskCleanupError.unsafeTrashLocation(
                candidate.path,
                "the item could not be revalidated: \(error.localizedDescription)"
            )
        }
    }

    private func protectionReason(
        for url: URL,
        category: DiskCleanupCategory,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        isUbiquitous: Bool
    ) -> String? {
        if isSymbolicLink {
            return "Symbolic links are protected."
        }
        if isUbiquitous {
            return "iCloud-synced items are protected."
        }

        guard category == .largestFiles || category == .largeFolders else {
            return nil
        }
        let candidate = url.standardizedFileURL
        if shouldExcludeHomeSubtree(candidate) {
            return "System-managed Library and Trash locations are protected."
        }
        if let components = relativeComponents(of: candidate, from: homeDirectory),
           let topLevelName = components.first,
           topLevelName.hasPrefix(".") {
            return "Hidden home configuration is protected."
        }
        if isDirectory,
           candidate.deletingLastPathComponent() == homeDirectory,
           protectedHomeAnchorNames.contains(candidate.lastPathComponent) {
            return "Open this standard folder and choose the items inside it."
        }
        return nil
    }

    private func shouldExcludeHomeSubtree(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        let trash = homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
        return Self.isDescendantOrEqual(candidate, of: library)
            || Self.isDescendantOrEqual(candidate, of: trash)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func relativeComponents(of url: URL, from root: URL) -> [String]? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = url.standardizedFileURL.pathComponents
        guard candidateComponents.starts(with: rootComponents),
              candidateComponents.count > rootComponents.count else {
            return nil
        }
        return Array(candidateComponents.dropFirst(rootComponents.count))
    }

    private func directChildPath(containing url: URL, under root: URL) -> String? {
        guard let name = relativeComponents(of: url, from: root)?.first else {
            return nil
        }
        return root.appendingPathComponent(name).standardizedFileURL.path
    }

    private func checkCancellation(
        _ cancellationToken: DiskCleanupCancellationToken
    ) throws {
        if cancellationToken.isCancelled {
            throw DiskCleanupError.cancelled
        }
    }

    private static func diskSize(_ values: URLResourceValues) -> UInt64 {
        if let allocated = values.totalFileAllocatedSize {
            return UInt64(max(0, allocated))
        }
        if let logical = values.fileSize {
            return UInt64(max(0, logical))
        }
        return 0
    }

    private static func sortLargestFirst(
        _ lhs: DiskCleanupItem,
        _ rhs: DiskCleanupItem
    ) -> Bool {
        if lhs.sizeBytes != rhs.sizeBytes {
            return lhs.sizeBytes > rhs.sizeBytes
        }
        return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
    }

    private static func isDescendantOrEqual(_ candidate: URL, of root: URL) -> Bool {
        candidate.standardizedFileURL.pathComponents.starts(
            with: root.standardizedFileURL.pathComponents
        )
    }

    fileprivate static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return code == .EACCES || code == .EPERM
        }
        return false
    }
}

private struct DirectoryAccumulator {
    let url: URL
    let name: String
    let kind: DiskCleanupItemKind
    let modificationDate: Date?
    let protectionReason: String?
    var sizeBytes: UInt64 = 0
    var fileCount: Int = 0

    func item(scanIncomplete: Bool) -> DiskCleanupItem {
        DiskCleanupItem(
            url: url,
            name: name,
            kind: kind,
            sizeBytes: sizeBytes,
            fileCount: fileCount,
            modificationDate: modificationDate,
            protectionReason: scanIncomplete
                ? "This item could not be measured completely and is protected."
                : protectionReason
        )
    }
}

private enum DirectoryScanContext {
    case root
    case accumulator(Int)
}

private struct DiskScanCounters {
    var skippedItemCount = 0
    var permissionDeniedCount = 0
    var excludedCloudItemCount = 0

    mutating func record(_ error: Error) {
        if DiskCleanupService.isPermissionError(error) {
            permissionDeniedCount += 1
        } else {
            skippedItemCount += 1
        }
    }

    mutating func add(_ other: DiskScanCounters) {
        skippedItemCount += other.skippedItemCount
        permissionDeniedCount += other.permissionDeniedCount
        excludedCloudItemCount += other.excludedCloudItemCount
    }
}

private struct LargestFilesPartial {
    var largest: BoundedLargestItems
    var counters = DiskScanCounters()
}

private struct DirectoryScanPartial {
    var sizes: [UInt64]
    var fileCounts: [Int]
    var incompleteIndices: Set<Int> = []
    var counters = DiskScanCounters()

    init(accumulatorCount: Int) {
        sizes = Array(repeating: 0, count: accumulatorCount)
        fileCounts = Array(repeating: 0, count: accumulatorCount)
    }
}

private struct BoundedLargestItems {
    let limit: Int
    private var heap: [DiskCleanupItem] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    mutating func insert(_ item: DiskCleanupItem) {
        if heap.count < limit {
            heap.append(item)
            siftUp(from: heap.count - 1)
            return
        }

        guard let smallest = heap.first, Self.isPreferred(item, over: smallest) else {
            return
        }
        heap[0] = item
        siftDown(from: 0)
    }

    /// Cheap pre-check so files that cannot enter a full heap skip building an item.
    func mightAccept(sizeBytes: UInt64) -> Bool {
        guard heap.count >= limit, let smallest = heap.first else { return true }
        return sizeBytes >= smallest.sizeBytes
    }

    mutating func merge(_ other: BoundedLargestItems) {
        for item in other.heap {
            insert(item)
        }
    }

    var sortedItems: [DiskCleanupItem] {
        heap.sorted {
            if $0.sizeBytes != $1.sizeBytes {
                return $0.sizeBytes > $1.sizeBytes
            }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    private mutating func siftUp(from startIndex: Int) {
        var child = startIndex
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.isLessDesirable(heap[child], than: heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from startIndex: Int) {
        var parent = startIndex
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { return }
            let right = left + 1
            var least = left
            if right < heap.count,
               Self.isLessDesirable(heap[right], than: heap[left]) {
                least = right
            }
            guard Self.isLessDesirable(heap[least], than: heap[parent]) else { return }
            heap.swapAt(parent, least)
            parent = least
        }
    }

    private static func isPreferred(
        _ candidate: DiskCleanupItem,
        over current: DiskCleanupItem
    ) -> Bool {
        if candidate.sizeBytes != current.sizeBytes {
            return candidate.sizeBytes > current.sizeBytes
        }
        return candidate.url.path.localizedStandardCompare(current.url.path) == .orderedAscending
    }

    private static func isLessDesirable(
        _ lhs: DiskCleanupItem,
        than rhs: DiskCleanupItem
    ) -> Bool {
        if lhs.sizeBytes != rhs.sizeBytes {
            return lhs.sizeBytes < rhs.sizeBytes
        }
        return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedDescending
    }
}
