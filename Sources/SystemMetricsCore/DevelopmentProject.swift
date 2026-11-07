import Darwin
import Foundation

public struct DevelopmentProjectContext: Equatable, Sendable {
    public let directory: URL
    public let branch: String?
    public var name: String { directory.lastPathComponent }
    public init(directory: URL, branch: String?) {
        self.directory = directory
        self.branch = branch
    }
}

public struct DevelopmentProjectMetadataError: LocalizedError, Sendable {
    public let project: DevelopmentProjectContext
    public let message: String
    public var errorDescription: String? { message }
}

public enum DevelopmentProjectResolver {
    public static func resolve(
        _ workingDirectory: URL, shouldContinue: @Sendable () -> Bool = { true }
    ) throws -> DevelopmentProjectContext {
        guard workingDirectory.isFileURL else { throw ProcessInspectionError(message: "The working directory must be a local path.") }
        let original = workingDirectory.standardizedFileURL
        var directory = original
        var manifestDirectory: URL?
        for _ in 0..<12 {
            guard shouldContinue() else { throw CancellationError() }
            let git = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                do {
                    let metadata: URL
                    if isDirectory.boolValue {
                        metadata = git
                    } else {
                        guard shouldContinue() else { throw CancellationError() }
                        let pointer = try readSmallFile(git).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard pointer.hasPrefix("gitdir: "), !pointer.dropFirst(8).isEmpty else {
                            throw ProcessInspectionError(message: "The project's Git directory pointer is invalid.")
                        }
                        let path = String(pointer.dropFirst(8))
                        metadata = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                            : directory.appendingPathComponent(path).standardizedFileURL
                    }
                    guard shouldContinue() else { throw CancellationError() }
                    if FileManager.default.fileExists(atPath: metadata.appendingPathComponent("reftable").path) {
                        throw ProcessInspectionError(message: "Git reftable branch metadata is not supported; the project directory remains available.")
                    }
                    guard shouldContinue() else { throw CancellationError() }
                    return DevelopmentProjectContext(
                        directory: directory, branch: try branch(readSmallFile(metadata.appendingPathComponent("HEAD")))
                    )
                } catch {
                    if error is CancellationError { throw error }
                    throw DevelopmentProjectMetadataError(
                        project: DevelopmentProjectContext(directory: directory, branch: nil),
                        message: error.localizedDescription
                    )
                }
            }
            if manifestDirectory == nil {
                for manifest in ["package.json", "Cargo.toml", "go.mod", "pom.xml", "build.gradle", "compose.yaml", "docker-compose.yml"] {
                    guard shouldContinue() else { throw CancellationError() }
                    if FileManager.default.fileExists(atPath: directory.appendingPathComponent(manifest).path) {
                        manifestDirectory = directory
                        break
                    }
                }
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return DevelopmentProjectContext(directory: manifestDirectory ?? original, branch: nil)
    }

    private static func branch(_ head: String) throws -> String {
        let value = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("ref: refs/heads/") {
            let name = String(value.dropFirst("ref: refs/heads/".count))
            guard !name.isEmpty, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ProcessInspectionError(message: "The project's Git branch is unreadable.")
            }
            return name
        }
        guard [40, 64].contains(value.utf8.count),
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw ProcessInspectionError(message: "The project's Git HEAD is unreadable.")
        }
        return "Detached \(value.prefix(8))"
    }

    private static func readSmallFile(_ url: URL) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ProcessInspectionError(message: "Cannot read Git metadata: \(String(cString: strerror(errno))).")
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= 4_096 else {
            throw ProcessInspectionError(message: "Git metadata must be a small regular file, not a symlink.")
        }
        var bytes = [UInt8](repeating: 0, count: 4_097)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count >= 0, count <= 4_096, let value = String(bytes: bytes.prefix(max(0, count)), encoding: .utf8) else {
            throw ProcessInspectionError(message: "Git metadata is unavailable or is not readable UTF-8 text.")
        }
        return value
    }
}

public enum ProcessWorkingDirectoryReader {
    public static func read(_ identity: ActivityProcessIdentity) throws -> URL {
        try ProcessLifetimeReader.validate(identity, presence: ProcessLifetimeReader.presence(
            pid: identity.pid, bootSession: identity.bootSession
        ))
        var info = proc_vnodepathinfo()
        let size = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(identity.pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        }
        guard size == MemoryLayout<proc_vnodepathinfo>.size else {
            throw ProcessInspectionError(message: "macOS did not expose this process's working directory.")
        }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) {
            String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8)
        }
        try ProcessLifetimeReader.validate(identity, presence: ProcessLifetimeReader.presence(
            pid: identity.pid, bootSession: identity.bootSession
        ))
        guard let path, path.hasPrefix("/") else {
            throw ProcessInspectionError(message: "macOS returned an unreadable working-directory path.")
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
