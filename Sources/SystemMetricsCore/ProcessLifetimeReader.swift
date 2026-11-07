import Darwin
import Foundation

public enum ProcessLifetimeReader {
    public static let bootSessionIdentifier: String = {
        var buffer = [CChar](repeating: 0, count: 128)
        var size = buffer.count
        if sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 {
            return String(cString: buffer)
        }
        fputs("KillSwitch could not read the boot identity; process history will use a new session identity.\n", stderr)
        return UUID().uuidString
    }()

    public static func snapshot(bootSession: String = bootSessionIdentifier) throws -> [Int32: ActivityProcessIdentity] {
        let capacity = max(256, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { throw ProcessInspectionError(message: "macOS did not provide a process identity inventory.") }
        var result: [Int32: ActivityProcessIdentity] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            if let identity = read(pid: pid, bootSession: bootSession) { result[pid] = identity }
        }
        return result
    }

    public static func validate(_ identity: ActivityProcessIdentity, presence: ProcessLifetimePresence) throws {
        switch presence {
        case .present(let current) where current == identity: return
        case .present:
            throw ProcessInspectionError(message: "This PID now belongs to a different process. Close this inspection and select the current process.")
        case .absent, .defunct:
            throw ProcessInspectionError(message: "This process has exited. Its saved resource history may still be available.")
        case .unavailable:
            throw ProcessInspectionError(message: "macOS could not verify this process's lifetime. Refresh to retry.")
        }
    }

    public static func read(pid: Int32, bootSession: String) -> ActivityProcessIdentity? {
        presence(pid: pid, bootSession: bootSession).identity
    }

    public static func presence(pid: Int32, bootSession: String) -> ProcessLifetimePresence {
        guard pid > 0 else { return .unavailable }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let status = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, UInt32($0.count), &info, &size, nil, 0)
        }
        return presence(info: info, pid: pid, bootSession: bootSession, status: status, size: size, error: errno)
    }

    public static func presence(
        info: kinfo_proc, pid: Int32, bootSession: String, status: Int32, size: Int, error: Int32
    ) -> ProcessLifetimePresence {
        guard pid > 0 else { return .unavailable }
        if status != 0 { return error == ESRCH ? .absent : .unavailable }
        if size == 0 { return .absent }
        guard size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else { return .unavailable }
        if Int32(info.kp_proc.p_stat) == SZOMB { return .defunct }
        guard let identity = identity(info: info, pid: pid, bootSession: bootSession) else { return .unavailable }
        return .present(identity)
    }

    public static func identity(
        info: kinfo_proc, pid: Int32, bootSession: String
    ) -> ActivityProcessIdentity? {
        let start = info.kp_proc.p_un.__p_starttime
        guard info.kp_proc.p_pid == pid, Int32(info.kp_proc.p_stat) != SZOMB, start.tv_sec > 0,
              start.tv_usec >= 0, start.tv_usec < 1_000_000 else { return nil }
        let seconds = UInt64(start.tv_sec)
        guard seconds <= (UInt64.max - UInt64(start.tv_usec)) / 1_000_000 else { return nil }
        return ActivityProcessIdentity(
            bootSession: bootSession, pid: pid,
            startTime: seconds * 1_000_000 + UInt64(start.tv_usec)
        )
    }
}
