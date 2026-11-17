import Darwin
import Foundation
import SoftwareInventoryCore

// MARK: - Disk images

public struct AttachedDiskImage: Equatable, Sendable {
    public let imagePath: String
    public let ownerUID: UInt32?
    public let isWriteable: Bool
    /// The whole-disk device, for example `/dev/disk7`.
    public let wholeDisk: String?
    public let mountPoints: [String]

    public init(imagePath: String, ownerUID: UInt32?, isWriteable: Bool, wholeDisk: String?, mountPoints: [String]) {
        self.imagePath = imagePath
        self.ownerUID = ownerUID
        self.isWriteable = isWriteable
        self.wholeDisk = wholeDisk
        self.mountPoints = mountPoints
    }
}

public enum DiskImageInspector {
    public static let infoCommand = SoftwareCommand("/usr/bin/hdiutil", arguments: ["info", "-plist"])

    /// Normal detach only; KillSwitch never force-ejects an image.
    public static func detachCommand(_ device: String) -> SoftwareCommand {
        SoftwareCommand("/usr/bin/hdiutil", arguments: ["detach", device])
    }

    public static func read(runner: SoftwareCommandRunning) throws -> [AttachedDiskImage] {
        let result = try runner.run(infoCommand)
        guard result.succeeded else {
            throw MaintenanceError.inspectionFailed("hdiutil info exited with status \(result.status): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return try parse(Data(result.output.utf8))
    }

    public static func parse(_ data: Data) throws -> [AttachedDiskImage] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw MaintenanceError.inspectionFailed("hdiutil info did not return a property list.")
        }
        return (root["images"] as? [[String: Any]] ?? []).compactMap { image in
            guard let path = image["image-path"] as? String else { return nil }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let devices = entities.compactMap { $0["dev-entry"] as? String }
            return AttachedDiskImage(
                imagePath: path,
                ownerUID: (image["owner-uid"] as? NSNumber)?.uint32Value,
                isWriteable: (image["writeable"] as? Bool) ?? true,
                wholeDisk: devices.first { $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil },
                mountPoints: entities.compactMap { $0["mount-point"] as? String }
            )
        }
    }
}

// MARK: - Artifact inspection

public struct DirectoryInspection: Equatable, Sendable {
    public var sizeBytes: UInt64 = 0
    public var fileCount = 0
    public var nestedGitPaths: [String] = []
    public var localConfigurationPaths: [String] = []
    public var unreadableCount = 0
}

public enum ArtifactInspector {
    public static let installerExtensions: Set<String> = ["dmg", "pkg"]
    public static let packagingMarkers: Set<String> = [
        "dist", "build", "out", "release", "releases", "package", "packages", "packaging",
        "staging", "stage", "image", "bundle", "installer", "installers", "artifacts"
    ]

    public static func isInstaller(_ name: String) -> Bool {
        installerExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    public static func archiveKind(_ name: String) -> String? {
        let lower = name.lowercased()
        if lower.hasSuffix(".zip") { return "zip" }
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return "tar" }
        return nil
    }

    /// A staged application bundle inside a generated packaging directory.
    public static func isStagedApplication(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map { $0.lowercased() }
        guard let last = components.last, last.hasSuffix(".app"), components.count > 1 else { return false }
        return components.dropLast().contains { component in
            packagingMarkers.contains(component) || component.contains("package") || component.contains("dist")
        }
    }

    /// Local configuration and secrets that must never leave with generated output.
    public static func isLocalConfiguration(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == ".env" { return true }
        if lower.hasPrefix(".env.") {
            return ![".env.example", ".env.sample", ".env.template", ".env.dist"].contains(lower)
        }
        if ["id_rsa", "id_ed25519", "id_ecdsa", ".netrc", ".npmrc", ".pypirc", "credentials.json", "secrets.json"].contains(lower) {
            return true
        }
        return ["pem", "p12", "pfx", "key", "keystore", "jks", "mobileprovision"].contains((lower as NSString).pathExtension)
    }

    /// Walks without following links. Nested `.git` entries are recorded and not entered.
    public static func inspect(
        _ path: String, checkLocalConfiguration: Bool, fileManager: FileManager = .default
    ) -> DirectoryInspection {
        var inspection = DirectoryInspection()
        let root = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        if let values = try? root.resourceValues(forKeys: Set(keys)), values.isDirectory != true {
            inspection.sizeBytes = UInt64(max(0, values.totalFileAllocatedSize ?? values.fileSize ?? 0))
            inspection.fileCount = 1
            if checkLocalConfiguration, isLocalConfiguration(root.lastPathComponent) { inspection.localConfigurationPaths.append(path) }
            return inspection
        }
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in
            inspection.unreadableCount += 1
            return true
        }) else {
            inspection.unreadableCount += 1
            return inspection
        }
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == ".git" {
                inspection.nestedGitPaths.append(url.path)
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                inspection.unreadableCount += 1
                continue
            }
            if values.isSymbolicLink == true { continue }
            if checkLocalConfiguration, isLocalConfiguration(url.lastPathComponent) {
                inspection.localConfigurationPaths.append(url.path)
            }
            if values.isRegularFile == true {
                inspection.sizeBytes += UInt64(max(0, values.totalFileAllocatedSize ?? values.fileSize ?? 0))
                inspection.fileCount += 1
            }
        }
        return inspection
    }

    /// Lists an archive without extracting it; an installer archive has an `.app` bundle
    /// at its top level or one folder down.
    public static func archiveContainsApplication(_ path: String, runner: SoftwareCommandRunning) -> Bool {
        guard let kind = archiveKind((path as NSString).lastPathComponent) else { return false }
        let command = kind == "zip"
            ? SoftwareCommand("/usr/bin/zipinfo", arguments: ["-1", path])
            : SoftwareCommand("/usr/bin/tar", arguments: ["-tzf", path])
        guard let result = try? runner.run(command), result.succeeded else { return false }
        return result.output.split(separator: "\n").contains { line in
            let parts = line.split(separator: "/", omittingEmptySubsequences: true)
            guard let index = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return false }
            return index <= 1 && !parts[..<index].contains { $0.hasPrefix("__MACOSX") }
        }
    }

    /// Volume free space for the home folder's volume, for reporting actual space changes.
    public static func availableBytes(at path: String) -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }
}

/// Moves an item to the Trash; items stay recoverable until the Trash is emptied.
public typealias MaintenanceTrashMover = (URL) throws -> Void

public enum MaintenanceTrash {
    public static let system: MaintenanceTrashMover = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
