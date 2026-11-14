import Foundation

/// Lists a directory tree on several worker threads. Every discovered subdirectory
/// becomes shared work, so folders with many subfolders fan out across idle workers.
/// Each worker owns one `Partial` result; the caller merges them after the walk.
final class ParallelDirectoryWalk<Context, Partial> {
    typealias ListingFailure = (inout Partial, URL, Context, Error) -> Void
    /// Returns the context for descending into the entry, or `nil` to skip its contents.
    typealias Visitor = (inout Partial, URL, Context) -> Context?

    private struct WorkItem {
        let url: URL
        let context: Context
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
        pending = [WorkItem(url: root, context: context)]
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

        var subdirectories: [WorkItem] = []
        var unreportedCount = 0
        for (offset, url) in entries.enumerated() {
            if offset % Self.cancellationCheckInterval == 0, cancellationToken.isCancelled {
                stop()
                return []
            }
            if let childContext = visit(&partial, url, item.context) {
                subdirectories.append(WorkItem(url: url, context: childContext))
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
        return subdirectories
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
