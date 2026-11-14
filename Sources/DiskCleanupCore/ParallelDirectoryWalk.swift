import Foundation

/// Reported when a queued folder is no longer the directory that was discovered,
/// for example because it was replaced by a symbolic link before it was listed.
struct DirectoryChangedDuringScanError: LocalizedError {
    let path: String

    var errorDescription: String? {
        "The folder changed while it was being scanned: \(path)"
    }
}

/// Lists a directory tree on several worker threads. Every discovered subdirectory
/// becomes shared work, so folders with many subfolders fan out across idle workers.
/// Each worker owns one `Partial` result; the caller merges them after the walk.
///
/// Queued folders remember the device and inode seen when they were discovered.
/// Before listing, a folder is opened without following a final symbolic link and the
/// descriptor's identity is compared; the descriptor stays open so the inode cannot be
/// reused. `contentsOfDirectory` still reads by path, so the path is re-checked after
/// listing and again after its entries are visited. Any mismatch reports the folder to
/// `listingFailed`. A swap that is reverted between two checks can escape detection.
final class ParallelDirectoryWalk<Context, Partial> {
    typealias ListingFailure = (inout Partial, URL, Context, Error) -> Void
    /// Returns the context for descending into the entry, or `nil` to skip its contents.
    typealias Visitor = (inout Partial, URL, Context) -> Context?

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    private struct WorkItem {
        let url: URL
        let context: Context
        let identity: DirectoryIdentity
        /// Only the caller's root may be reached through a final symbolic link.
        let isRoot: Bool
    }

    private static var progressBatchSize: Int { 128 }
    private static var cancellationCheckInterval: Int { 64 }

    private let fileManager: FileManager
    private let resourceKeys: [URLResourceKey]
    private let options: FileManager.DirectoryEnumerationOptions
    private let workerCount: Int
    private let cancellationToken: DiskCleanupCancellationToken
    private let progress: DiskCleanupService.ProgressHandler?

    private let condition = NSCondition()
    private var pending: [WorkItem] = []
    private var activeWorkers = 0
    private var stopped = false
    private var partials: [Partial] = []

    private let progressLock = NSLock()
    private var scannedEntryCount = 0
    private var reporter: ProgressReporter

    init(
        fileManager: FileManager,
        resourceKeys: Set<URLResourceKey>,
        options: FileManager.DirectoryEnumerationOptions,
        workerCount: Int,
        progressStride: Int,
        progressInterval: TimeInterval,
        cancellationToken: DiskCleanupCancellationToken,
        progress: DiskCleanupService.ProgressHandler?
    ) {
        self.fileManager = fileManager
        self.resourceKeys = Array(resourceKeys)
        self.options = options
        self.workerCount = max(1, workerCount)
        self.cancellationToken = cancellationToken
        self.progress = progress
        self.reporter = ProgressReporter(stride: progressStride, minimumInterval: progressInterval)
    }

    /// Walks `root` once. Results are incomplete when the cancellation token fires;
    /// callers must check it before using them.
    func run(
        root: URL,
        context: Context,
        makePartial: () -> Partial,
        listingFailed: ListingFailure,
        visit: Visitor
    ) -> (partials: [Partial], scannedEntryCount: Int) {
        switch Self.directoryIdentity(atPath: root.path, followingFinalLink: true) {
        case .success(let identity):
            pending = [WorkItem(url: root, context: context, identity: identity, isRoot: true)]
        case .failure(let error):
            var partial = makePartial()
            listingFailed(&partial, root, context, error)
            return ([partial], 0)
        }
        if workerCount == 1 {
            work(makePartial: makePartial, listingFailed: listingFailed, visit: visit)
        } else {
            DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
                work(makePartial: makePartial, listingFailed: listingFailed, visit: visit)
            }
        }
        return (partials, scannedEntryCount)
    }

    private func work(
        makePartial: () -> Partial,
        listingFailed: ListingFailure,
        visit: Visitor
    ) {
        var partial = makePartial()
        while let item = nextItem() {
            let subdirectories = list(
                item,
                into: &partial,
                listingFailed: listingFailed,
                visit: visit
            )
            finish(discovering: subdirectories)
        }
        condition.lock()
        partials.append(partial)
        condition.unlock()
    }

    private func nextItem() -> WorkItem? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty, activeWorkers > 0, !stopped {
            condition.wait()
        }
        guard !stopped, let item = pending.popLast() else { return nil }
        activeWorkers += 1
        return item
    }

    private func finish(discovering subdirectories: [WorkItem]) {
        condition.lock()
        if !stopped {
            pending.append(contentsOf: subdirectories)
        }
        activeWorkers -= 1
        if !subdirectories.isEmpty || activeWorkers == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    private func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    private func list(
        _ item: WorkItem,
        into partial: inout Partial,
        listingFailed: ListingFailure,
        visit: Visitor
    ) -> [WorkItem] {
        guard !cancellationToken.isCancelled else {
            stop()
            return []
        }

        // Holding the descriptor keeps the inode allocated, so a matching identity
        // cannot belong to a different folder created after this one was removed.
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (item.isRoot ? 0 : O_NOFOLLOW)
        let descriptor = open(item.url.path, flags)
        guard descriptor >= 0 else {
            listingFailed(&partial, item.url, item.context, Self.posixError(errno, item: item))
            return []
        }
        defer { close(descriptor) }
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              DirectoryIdentity(openedInfo) == item.identity else {
            listingFailed(&partial, item.url, item.context, DirectoryChangedDuringScanError(path: item.url.path))
            return []
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: item.url,
                includingPropertiesForKeys: resourceKeys,
                options: options
            )
        } catch {
            listingFailed(&partial, item.url, item.context, error)
            return []
        }
        guard pathStillResolves(to: item) else {
            listingFailed(&partial, item.url, item.context, DirectoryChangedDuringScanError(path: item.url.path))
            return []
        }

        var subdirectories: [WorkItem] = []
        var unreportedCount = 0
        for (offset, url) in entries.enumerated() {
            if offset % Self.cancellationCheckInterval == 0, cancellationToken.isCancelled {
                stop()
                return []
            }
            if let childContext = visit(&partial, url, item.context) {
                switch Self.directoryIdentity(atPath: url.path, followingFinalLink: false) {
                case .success(let identity):
                    subdirectories.append(
                        WorkItem(url: url, context: childContext, identity: identity, isRoot: false)
                    )
                case .failure(let error):
                    listingFailed(&partial, url, childContext, error)
                }
            }
            unreportedCount += 1
            if unreportedCount == Self.progressBatchSize {
                record(unreportedCount, currentURL: url)
                unreportedCount = 0
            }
        }
        if unreportedCount > 0 {
            record(unreportedCount, currentURL: entries.last ?? item.url)
        }
        // A path swapped while entries were visited may have exposed another tree.
        guard pathStillResolves(to: item) else {
            listingFailed(&partial, item.url, item.context, DirectoryChangedDuringScanError(path: item.url.path))
            return []
        }
        return subdirectories
    }

    private func pathStillResolves(to item: WorkItem) -> Bool {
        guard case .success(let identity) = Self.directoryIdentity(
            atPath: item.url.path,
            followingFinalLink: item.isRoot
        ) else {
            return false
        }
        return identity == item.identity
    }

    private static func directoryIdentity(
        atPath path: String,
        followingFinalLink: Bool
    ) -> Result<DirectoryIdentity, Error> {
        var info = stat()
        let status = followingFinalLink ? stat(path, &info) : lstat(path, &info)
        guard status == 0 else {
            return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return .failure(DirectoryChangedDuringScanError(path: path))
        }
        return .success(DirectoryIdentity(info))
    }

    private static func posixError(_ code: Int32, item: WorkItem) -> Error {
        // O_NOFOLLOW reports a final symbolic link as ELOOP; ENOTDIR means it is no longer a folder.
        if !item.isRoot, code == ELOOP || code == ENOTDIR {
            return DirectoryChangedDuringScanError(path: item.url.path)
        }
        return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private func record(_ count: Int, currentURL: URL) {
        progressLock.lock()
        defer { progressLock.unlock() }
        scannedEntryCount += count
        guard reporter.shouldReport(scannedEntryCount: scannedEntryCount) else { return }
        progress?(DiskCleanupProgress(
            scannedEntryCount: scannedEntryCount,
            currentURL: currentURL
        ))
    }
}

struct ProgressReporter {
    let stride: Int
    let minimumInterval: TimeInterval
    private var lastReportCount = 0
    private var lastReportTime = Date.distantPast

    init(stride: Int, minimumInterval: TimeInterval) {
        self.stride = stride
        self.minimumInterval = minimumInterval
    }

    mutating func shouldReport(scannedEntryCount: Int) -> Bool {
        guard scannedEntryCount - lastReportCount >= stride else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastReportTime) >= minimumInterval else { return false }
        lastReportCount = scannedEntryCount
        lastReportTime = now
        return true
    }
}
