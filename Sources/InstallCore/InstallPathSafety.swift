import Foundation

public enum InstallPathSafetyError: LocalizedError, Equatable {
    case occupiedDirectory(String)
    case occupiedNonSymbolicLink(String)

    public var errorDescription: String? {
        switch self {
        case .occupiedDirectory(let path):
            return "Refusing to modify directory at \(path). Move it before installing, updating, or uninstalling KillSwitch."
        case .occupiedNonSymbolicLink(let path):
            return "Refusing to modify non-symlink at \(path). Move it before installing, updating, or uninstalling KillSwitch."
        }
    }
}

public enum ManagedSymbolicLinkRemovalResult: Equatable {
    case absent
    case removed
}

public enum InstallPathSafety {
    public static func validateReplaceableBinary(
        at path: String,
        fileManager: FileManager = .default
    ) throws {
        if case .directory = inspect(path, fileManager: fileManager) {
            throw InstallPathSafetyError.occupiedDirectory(path)
        }
    }

    public static func validateManagedSymbolicLink(
        at path: String,
        fileManager: FileManager = .default
    ) throws {
        switch inspect(path, fileManager: fileManager) {
        case .absent, .symbolicLink:
            return
        case .directory, .other:
            throw InstallPathSafetyError.occupiedNonSymbolicLink(path)
        }
    }

    public static func removeReplaceableBinaryIfPresent(
        at path: String,
        fileManager: FileManager = .default
    ) throws {
        let kind = inspect(path, fileManager: fileManager)
        if case .directory = kind {
            throw InstallPathSafetyError.occupiedDirectory(path)
        }
        if kind != .absent {
            try fileManager.removeItem(atPath: path)
        }
    }

    @discardableResult
    public static func removeManagedSymbolicLinkIfPresent(
        at path: String,
        fileManager: FileManager = .default
    ) throws -> ManagedSymbolicLinkRemovalResult {
        let kind = inspect(path, fileManager: fileManager)
        switch kind {
        case .absent:
            return .absent
        case .symbolicLink:
            try fileManager.removeItem(atPath: path)
            return .removed
        case .directory, .other:
            throw InstallPathSafetyError.occupiedNonSymbolicLink(path)
        }
    }

    private enum PathKind: Equatable {
        case absent
        case symbolicLink
        case directory
        case other
    }

    private static func inspect(_ path: String, fileManager: FileManager) -> PathKind {
        if (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil {
            return .symbolicLink
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .absent
        }
        return isDirectory.boolValue ? .directory : .other
    }
}
