import Darwin

public enum ProcessLifetimeReader {
    public static func read(pid: Int32, bootSession: String) -> ActivityProcessIdentity? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let status = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, UInt32($0.count), &info, &size, nil, 0)
        }
        guard status == 0, size == MemoryLayout<kinfo_proc>.size else { return nil }
        return identity(info: info, pid: pid, bootSession: bootSession)
    }

    public static func identity(
        info: kinfo_proc, pid: Int32, bootSession: String
    ) -> ActivityProcessIdentity? {
        let start = info.kp_proc.p_un.__p_starttime
        guard info.kp_proc.p_pid == pid, start.tv_sec > 0,
              start.tv_usec >= 0, start.tv_usec < 1_000_000 else { return nil }
        let seconds = UInt64(start.tv_sec)
        guard seconds <= (UInt64.max - UInt64(start.tv_usec)) / 1_000_000 else { return nil }
        return ActivityProcessIdentity(
            bootSession: bootSession, pid: pid,
            startTime: seconds * 1_000_000 + UInt64(start.tv_usec)
        )
    }
}
