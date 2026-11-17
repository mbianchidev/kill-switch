import Foundation

/// Reads a process's argument vector so classifiers do not have to guess argument boundaries from flattened `ps` output.
public enum ProcessArguments {
    /// argv for `pid`, or nil when it is unreadable (another user's process, exited, or malformed).
    public static func read(pid: Int32) -> [String]? {
        var argumentLimit: Int32 = 0
        var limitSize = MemoryLayout<Int32>.size
        var limitName: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&limitName, 2, &argumentLimit, &limitSize, nil, 0) == 0, argumentLimit > 0 else { return nil }

        var size = Int(argumentLimit)
        var buffer = [UInt8](repeating: 0, count: size)
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(procArgs2: buffer.prefix(size))
    }

    /// Parses a `KERN_PROCARGS2` buffer: native `Int32` argc, executable path, NUL padding, then argc NUL-terminated arguments.
    public static func parse<Bytes: Collection>(procArgs2 bytes: Bytes) -> [String]? where Bytes.Element == UInt8 {
        let bytes = Array(bytes)
        let countSize = MemoryLayout<Int32>.size
        guard bytes.count > countSize else { return nil }
        let count = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard count > 0 else { return nil }

        var index = countSize
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            guard index < bytes.count, let argument = String(bytes: bytes[start..<index], encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
            index += 1
        }
        return arguments
    }
}
