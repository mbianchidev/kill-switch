import Foundation

public enum DiskCleanupCategory: String, CaseIterable, Hashable {
    case largestFiles
    case temporary
    case caches
    case largeFolders
}

public enum DiskCleanupItemKind: Equatable {
    case file
    case directory
    case package
}

public struct DiskCleanupItem: Identifiable, Equatable {
    public var id: String { url.standardizedFileURL.path }

    public let url: URL
    public let name: String
    public let kind: DiskCleanupItemKind
    public let sizeBytes: UInt64
    public let fileCount: Int
    public let modificationDate: Date?
    public let protectionReason: String?

    public var canTrash: Bool { protectionReason == nil }

    public init(
        url: URL,
        name: String,
        kind: DiskCleanupItemKind,
        sizeBytes: UInt64,
        fileCount: Int,
        modificationDate: Date?,
        protectionReason: String?
    ) {
        self.url = url
        self.name = name
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.modificationDate = modificationDate
        self.protectionReason = protectionReason
    }
}

public struct DiskCleanupProgress: Equatable {
    public let scannedEntryCount: Int
    public let currentURL: URL

    public init(scannedEntryCount: Int, currentURL: URL) {
        self.scannedEntryCount = scannedEntryCount
        self.currentURL = currentURL
    }
}

public struct DiskCleanupScanResult: Equatable {
    public let category: DiskCleanupCategory
    public let rootURL: URL
    public let items: [DiskCleanupItem]
    public let scannedEntryCount: Int
    public let skippedItemCount: Int
    public let permissionDeniedCount: Int
    public let excludedCloudItemCount: Int

    public init(
        category: DiskCleanupCategory,
        rootURL: URL,
        items: [DiskCleanupItem],
        scannedEntryCount: Int,
        skippedItemCount: Int,
        permissionDeniedCount: Int,
        excludedCloudItemCount: Int
    ) {
        self.category = category
        self.rootURL = rootURL
        self.items = items
        self.scannedEntryCount = scannedEntryCount
        self.skippedItemCount = skippedItemCount
        self.permissionDeniedCount = permissionDeniedCount
        self.excludedCloudItemCount = excludedCloudItemCount
    }
}

public struct DiskCleanupTrashFailure: Equatable {
    public let item: DiskCleanupItem
    public let message: String

    public init(item: DiskCleanupItem, message: String) {
        self.item = item
        self.message = message
    }
}

public struct DiskCleanupTrashResult: Equatable {
    public let movedItems: [DiskCleanupItem]
    public let failures: [DiskCleanupTrashFailure]

    public init(movedItems: [DiskCleanupItem], failures: [DiskCleanupTrashFailure]) {
        self.movedItems = movedItems
        self.failures = failures
    }
}

public final class DiskCleanupCancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public enum DiskCleanupError: LocalizedError, Equatable {
    case cancelled
    case unavailableRoot(String)
    case invalidScanLocation(String)
    case unreadableDirectory(String, String)
    case unsafeTrashLocation(String, String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The disk scan was cancelled."
        case .unavailableRoot(let path):
            return "The cleanup location is unavailable: \(path)"
        case .invalidScanLocation(let path):
            return "Refusing to scan outside the selected cleanup location: \(path)"
        case .unreadableDirectory(let path, let message):
            return "Could not read \(path): \(message)"
        case .unsafeTrashLocation(let path, let reason):
            return "Refusing to move \(path) to Trash: \(reason)"
        }
    }
}
