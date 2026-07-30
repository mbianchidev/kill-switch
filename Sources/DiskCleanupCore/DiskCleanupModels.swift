import Foundation

public enum DiskCleanupCategory: String, CaseIterable, Hashable, Sendable {
    case largestFiles
    case temporary
    case caches
    case largeFolders
}

public enum DiskCleanupItemKind: Equatable, Sendable {
    case file
    case directory
    case package
}

public struct DiskCleanupItem: Identifiable, Equatable, Sendable {
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

public struct DiskCleanupProgress: Equatable, Sendable {
    public let scannedEntryCount: Int
    public let currentURL: URL

    public init(scannedEntryCount: Int, currentURL: URL) {
        self.scannedEntryCount = scannedEntryCount
        self.currentURL = currentURL
    }
}

public struct DiskCleanupScanResult: Equatable, Sendable {
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

public struct DiskCleanupScanDelta: Equatable, Sendable {
    public let addedItems: [DiskCleanupItem]
    public let updatedItems: [DiskCleanupItem]
    public let removedItems: [DiskCleanupItem]

    private let orderedItemIDs: [String]

    public init(
        previousItems: [DiskCleanupItem],
        currentItems: [DiskCleanupItem]
    ) {
        var previousByID: [String: DiskCleanupItem] = [:]
        for item in previousItems {
            previousByID[item.id] = item
        }

        var currentByID: [String: DiskCleanupItem] = [:]
        for item in currentItems {
            currentByID[item.id] = item
        }

        addedItems = currentItems.filter { previousByID[$0.id] == nil }
        updatedItems = currentItems.filter { item in
            guard let previous = previousByID[item.id] else { return false }
            return previous != item
        }
        removedItems = previousItems.filter { currentByID[$0.id] == nil }
        orderedItemIDs = currentItems.map(\.id)
    }

    public var changeCount: Int {
        addedItems.count + updatedItems.count + removedItems.count
    }

    public var isEmpty: Bool {
        changeCount == 0
    }

    public func applying(to previousItems: [DiskCleanupItem]) -> [DiskCleanupItem] {
        var itemsByID: [String: DiskCleanupItem] = [:]
        for item in previousItems {
            itemsByID[item.id] = item
        }
        for item in removedItems {
            itemsByID.removeValue(forKey: item.id)
        }
        for item in updatedItems {
            itemsByID[item.id] = item
        }
        for item in addedItems {
            itemsByID[item.id] = item
        }
        return orderedItemIDs.compactMap { itemsByID[$0] }
    }
}

public struct DiskCleanupTrashFailure: Equatable, Sendable {
    public let item: DiskCleanupItem
    public let message: String

    public init(item: DiskCleanupItem, message: String) {
        self.item = item
        self.message = message
    }
}

public struct DiskCleanupTrashResult: Equatable, Sendable {
    public let movedItems: [DiskCleanupItem]
    public let failures: [DiskCleanupTrashFailure]

    public init(movedItems: [DiskCleanupItem], failures: [DiskCleanupTrashFailure]) {
        self.movedItems = movedItems
        self.failures = failures
    }
}

public final class DiskCleanupCancellationToken: @unchecked Sendable {
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

public enum DiskCleanupError: LocalizedError, Equatable, Sendable {
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
            return "Refusing to scan this cleanup location: \(path)"
        case .unreadableDirectory(let path, let message):
            return "Could not read \(path): \(message)"
        case .unsafeTrashLocation(let path, let reason):
            return "Refusing to move \(path) to Trash: \(reason)"
        }
    }
}
