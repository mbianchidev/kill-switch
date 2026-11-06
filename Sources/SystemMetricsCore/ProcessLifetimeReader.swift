import Darwin

public enum ProcessLifetimeReader {
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
