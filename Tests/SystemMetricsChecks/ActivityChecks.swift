import Darwin
import Foundation
import InstallCore
import SystemMetricsCore

extension SystemMetricsChecks {
    static func checkActivityHistory() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = ActivityProcessIdentity(bootSession: "test-boot", pid: 42, startTime: 100)
        let reusedPID = ActivityProcessIdentity(bootSession: "test-boot", pid: 42, startTime: 200)
        let nextBoot = ActivityProcessIdentity(bootSession: "next-boot", pid: 42, startTime: 100)
        check(Set([identity, reusedPID, nextBoot]).count == 3, "history separates PID reuse and boots")
        let sleepOwners: Set<ActivityProcessIdentity> = [identity]
        check(sleepOwners.contains(identity) && !sleepOwners.contains(reusedPID), "sleep assertions do not transfer to a replacement sharing the PID")
        checkProcessLifetimeReader()
        check(
            ActivityProcessIdentity.verified(pid: 42, before: [42: identity], after: [42: identity], current: identity) == identity,
            "PS fallback data requires one lifetime across both PS boundaries and native collection"
        )
        check(
            ActivityProcessIdentity.verified(pid: 42, before: [42: identity], after: [42: reusedPID], current: reusedPID) == nil,
            "PID reuse while PS is collected cannot attach old owner or memory to the replacement"
        )
        check(
            ActivityProcessIdentity.verified(pid: 42, before: [42: identity], after: [42: identity], current: reusedPID) == nil,
            "PID reuse after PS cannot attach its fallback data to a later native identity"
        )
        check(
            ActivityProcessIdentity.verified(pid: 42, before: [:], after: [42: identity], current: identity) == nil,
            "unbracketed PS fallback data remains unverified"
        )
        check(
            SystemMetricsParser.executableName("/Library/Application Support/Example/agent") == "agent",
            "argument-free executable names preserve paths containing spaces"
        )

        var rates = ActivityRateTracker()
        let first = rates.sample(
            identity: identity, date: start,
            diskRead: 100, diskWritten: 200, received: 300, sent: 400
        )
        check(first.diskRead == nil && first.received == nil, "first process rates are unavailable")
        let second = rates.sample(
            identity: identity, date: start.addingTimeInterval(6),
            diskRead: 700, diskWritten: 1_400, received: 2_100, sent: 2_800
        )
        check(second.diskRead == 100 && second.diskWritten == 200, "process disk rates use elapsed time")
        check(second.received == 300 && second.sent == 400, "process traffic rates use elapsed time")
        var independentlyTimed = ActivityRateTracker()
        _ = independentlyTimed.sample(
            identity: identity, date: start, diskRead: 0, diskWritten: 0, received: 0, sent: 0,
            diskDate: start, networkDate: start.addingTimeInterval(1)
        )
        let delayedNetwork = independentlyTimed.sample(
            identity: identity, date: start.addingTimeInterval(6),
            diskRead: 600, diskWritten: 600, received: 2_100, sent: 2_100,
            diskDate: start.addingTimeInterval(6), networkDate: start.addingTimeInterval(8)
        )
        check(delayedNetwork.diskRead == 100 && delayedNetwork.received == 300, "rate calculation uses each collector's real timestamp despite an energy delay")
        let undelayedNetwork = independentlyTimed.sample(
            identity: identity, date: start.addingTimeInterval(12),
            diskRead: 1_200, diskWritten: 1_200, received: 3_600, sent: 3_600,
            diskDate: start.addingTimeInterval(12), networkDate: start.addingTimeInterval(13)
        )
        check(undelayedNetwork.received == 300, "steady network traffic does not alternate between delayed spikes and dips")
        let reset = rates.sample(
            identity: identity, date: start.addingTimeInterval(12),
            diskRead: 1, diskWritten: nil, received: nil, sent: 1
        )
        check(reset.diskRead == nil && reset.sent == nil, "counter resets do not produce negative rates")
        check(reset.diskWritten == nil && reset.received == nil, "restricted counters remain unavailable")
        let reused = rates.sample(
            identity: reusedPID, date: start.addingTimeInterval(18),
            diskRead: 1_000, diskWritten: 1_000, received: 1_000, sent: 1_000
        )
        check(reused.diskRead == nil, "reused PID does not inherit disk counters")
        let afterSleep = rates.sample(
            identity: reusedPID, date: start.addingTimeInterval(3_600),
            diskRead: 2_000, diskWritten: 2_000, received: 2_000, sent: 2_000
        )
        check(afterSleep.received == nil, "long monitoring gaps do not invent live rates")

        var accumulator = ActivityAccumulator()
        let process = ActivityProcessDescriptor(identity: identity, name: "Example worker", user: "sample-user")
        checkLiveHistory(start: start, process: process)
        checkHistoryProcessDescriptors(start: start, process: process)
        let initial = ActivitySnapshot(
            date: start, system: ActivityValues(cpu: 10, memory: 100),
            processes: [ActivityProcessSample(process: process, values: ActivityValues(cpu: 20, memory: 200))]
        )
        check(accumulator.append(initial) == nil, "first minute remains pending")
        check(
            accumulator.append(ActivitySnapshot(
                date: start.addingTimeInterval(6),
                system: ActivityValues(cpu: 30, memory: nil),
                processes: [ActivityProcessSample(process: process, values: ActivityValues(cpu: 40, memory: 400))]
            )) == nil,
            "samples in one minute accumulate"
        )
        let completed = accumulator.append(ActivitySnapshot(
            date: start.addingTimeInterval(60), system: ActivityValues(cpu: 90), processes: []
        ))
        check(completed?.system.cpu == 20, "minute history averages measured CPU samples")
        check(completed?.date == start.addingTimeInterval(6), "history timestamps are actual last measurements, not invented minute boundaries")
        check(completed?.system.memory == 100, "missing samples are not averaged as zero")
        check(completed?.processes.first?.values.memory == 300, "minute history includes per-process memory")
        check(accumulator.current?.system.cpu == 90, "next minute starts a separate bucket")
        var buffer = ActivityWriteBuffer()
        buffer.append(initial, now: start)
        do {
            try buffer.flush { _ in throw ActivityHistoryError(message: "synthetic storage failure") }
            check(false, "failed history writes must report failure")
        } catch { check(buffer.count == 1, "failed history writes remain queued for retry") }
        var saved: [ActivitySnapshot] = []
        do { try buffer.flush { saved.append($0) } }
        catch { check(false, "retry history writes: \(error.localizedDescription)") }
        check(saved == [initial] && buffer.count == 0, "history retry persists and removes the queued bucket")
        buffer.append(initial, now: start)
        let expired = buffer.append(
            ActivitySnapshot(date: start.addingTimeInterval(360), system: ActivityValues(cpu: 1), processes: []),
            now: start.addingTimeInterval(360)
        )
        check(expired == 1 && buffer.count == 1, "unsaved history stays bounded and reports expired buckets")
        var resumedBuffer = ActivityWriteBuffer()
        let resumed = start.addingTimeInterval(6 * 3_600)
        check(resumedBuffer.append(initial, now: resumed) == 0, "a newly completed pre-sleep bucket is not an expired retry")
        do {
            var resumedWrites: [ActivitySnapshot] = []
            try resumedBuffer.flush { resumedWrites.append($0) }
            check(resumedWrites == [initial], "healthy storage receives the original pre-sleep measurements")
        } catch { check(false, "write pre-sleep bucket: \(error.localizedDescription)") }

        let points = [
            ActivityHistoryPoint(date: start, values: ActivityValues(cpu: 20)),
            ActivityHistoryPoint(date: start.addingTimeInterval(6), values: ActivityValues(cpu: nil)),
            ActivityHistoryPoint(date: start.addingTimeInterval(12), values: ActivityValues(cpu: 40)),
            ActivityHistoryPoint(date: start.addingTimeInterval(600), values: ActivityValues(cpu: 50))
        ]
        let series = ActivitySeries.points(points, metric: .cpu)
        check(series.count == 3, "unavailable readings are not plotted as zero")
        check(Set(series.map(\.segment)).count == 3, "charts break at missing samples and monitoring gaps")
        let cpuBands = ActivitySeries.points([
            ActivityHistoryPoint(date: start, values: ActivityValues(cpu: 70, cpuSystem: 20, cpuUser: 50))
        ], metric: .cpu, splitCPU: true)
        check(cpuBands.map(\.value) == [20, 70], "global CPU history preserves stacked system and user usage")
        check(cpuBands.map(\.lowerBound) == [0, 20], "user CPU band begins above the system band")
        check(ActivityHistoryRange.day.seconds == 86_400, "history retention range is exactly 24 hours")

        checkActivityStore(initial: initial, process: process, start: start)
        if CommandLine.arguments.contains("--memory-stress") {
            checkActivityMemoryFootprint(start: start)
        }
    }

    private static func checkLiveHistory(start: Date, process: ActivityProcessDescriptor) {
        var history = ActivityLiveHistory()
        func snapshot(_ seconds: TimeInterval) -> ActivitySnapshot {
            ActivitySnapshot(
                date: start.addingTimeInterval(seconds),
                system: ActivityValues(cpu: seconds),
                processes: [ActivityProcessSample(process: process, values: ActivityValues(memory: seconds))]
            )
        }
        for index in 0..<60 {
            history.append(snapshot(Double(index) / 10))
        }
        check(history.snapshots.count == 1, "rapid refreshes replace the current six-second history slot")
        check(history.snapshots.last?.date == start.addingTimeInterval(5.9), "coalescing keeps the real latest measurement time")
        check(history.snapshots.last?.processes.first?.values.memory == 5.9, "coalescing keeps the latest per-process values")

        var bounded = true
        for second in 6..<7_200 {
            history.append(snapshot(Double(second)))
            bounded = bounded && history.snapshots.count <= 51
        }
        check(bounded, "live history never exceeds 51 snapshots during hours of rapid refreshes")
        check(history.snapshots.count == 51, "coalescing preserves the full five-minute live window")
        check(
            history.snapshots.allSatisfy { $0.date >= start.addingTimeInterval(7_199 - 300) },
            "live history drops measurements outside its five-minute window"
        )
        history.append(snapshot(86_400))
        check(history.snapshots.count == 1, "resume drops old live snapshots without inventing gap samples")
        history.removeAll()
        check(history.snapshots.isEmpty, "clear history releases live snapshots")
    }

    private static func checkActivityMemoryFootprint(start: Date) {
        let processes = (0..<5_000).map { index in
            ActivityProcessDescriptor(
                identity: ActivityProcessIdentity(
                    bootSession: "synthetic-memory-boot", pid: Int32(index + 1_000), startTime: UInt64(index + 1)
                ),
                name: "Synthetic worker \(index)", user: "sample-user"
            )
        }
        var history = ActivityLiveHistory()
        var accumulator = ActivityAccumulator()
        for index in 0..<1_200 {
            autoreleasepool {
                let values = ActivityValues(
                    cpu: Double(index % 100), memory: Double(index * 1_024),
                    diskRead: 100, diskWritten: 200, received: 300, sent: 400
                )
                let snapshot = ActivitySnapshot(
                    date: start.addingTimeInterval(Double(index * 6)), system: values,
                    processes: processes.map { ActivityProcessSample(process: $0, values: values) }
                )
                history.append(snapshot)
                _ = accumulator.append(snapshot)
            }
        }
        check(history.snapshots.count == 51, "two synthetic hours with 5,000 processes retain only five live minutes")
        check(history.snapshots.last?.processes.count == 5_000, "memory bounds do not drop processes")
        check(accumulator.current?.processes.count == 5_000, "minute averages still include every synthetic process")
        check(
            history.processDescriptors(archived: [], accumulator: accumulator, pending: ActivityWriteBuffer()).count == 5_000,
            "the bounded selector catalog includes every synthetic process"
        )
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            check(false, "read the synthetic checks process memory usage: \(String(cString: strerror(errno)))")
            return
        }
        let limit = 256 * 1_024 * 1_024
        check(usage.ru_maxrss < limit, "synthetic history stress stays below 256 MiB peak resident memory")
        print("Activity memory stress: \(usage.ru_maxrss / 1_024 / 1_024) MiB peak RSS, 5,000 processes, two simulated hours")
    }

    private static func checkHistoryProcessDescriptors(start: Date, process: ActivityProcessDescriptor) {
        var history = ActivityLiveHistory()
        var accumulator = ActivityAccumulator()
        var pending = ActivityWriteBuffer()
        let brief = ActivitySnapshot(
            date: start, system: ActivityValues(),
            processes: [ActivityProcessSample(process: process, values: ActivityValues(cpu: 1))]
        )
        let exited = ActivitySnapshot(
            date: start.addingTimeInterval(0.1), system: ActivityValues(), processes: []
        )
        history.append(brief)
        _ = accumulator.append(brief)
        history.append(exited)
        _ = accumulator.append(exited)
        check(history.snapshots.last?.processes.isEmpty == true, "rapid refresh can replace a short-lived process measurement")
        check(
            history.processDescriptors(archived: [], accumulator: accumulator, pending: pending) == [process],
            "a coalesced short-lived process keeps its selector name and lifetime identity in the current minute"
        )

        let resumed = ActivitySnapshot(
            date: start.addingTimeInterval(6 * 3_600), system: ActivityValues(), processes: []
        )
        history.append(resumed)
        if let completed = accumulator.append(resumed) { pending.append(completed, now: resumed.date) }
        check(pending.count == 1, "the pre-sleep minute remains queued until persistence succeeds")
        check(
            history.processDescriptors(archived: [], accumulator: accumulator, pending: pending) == [process],
            "descriptors awaiting persistence remain selectable even after the live window expires"
        )
        do {
            try pending.flush { _ in throw ActivityHistoryError(message: "synthetic catalog storage failure") }
            check(false, "synthetic selector persistence failure must propagate")
        } catch {
            check(
                history.processDescriptors(archived: [], accumulator: accumulator, pending: pending) == [process],
                "storage failure does not hide a queued process name"
            )
        }
        do {
            var archived: [ActivityProcessDescriptor] = []
            try pending.flush { archived.append(contentsOf: $0.processes.map(\.process)) }
            check(
                history.processDescriptors(archived: archived, accumulator: accumulator, pending: pending) == [process],
                "successful persistence hands process descriptors to the archive without losing selection"
            )
        } catch { check(false, "persist synthetic selector descriptors: \(error.localizedDescription)") }
        history.removeAll()
        accumulator = ActivityAccumulator()
        pending = ActivityWriteBuffer()
        check(
            history.processDescriptors(archived: [], accumulator: accumulator, pending: pending).isEmpty,
            "clear history releases selector descriptors along with measurements"
        )
    }

    private static func checkProcessLifetimeReader() {
        var info = kinfo_proc()
        info.kp_proc.p_pid = 42
        info.kp_eproc.e_ucred.cr_uid = 502
        info.kp_proc.p_un.__p_starttime.tv_sec = 1_800_000_000
        info.kp_proc.p_un.__p_starttime.tv_usec = 123_456
        let identity = ProcessLifetimeReader.identity(info: info, pid: 42, bootSession: "synthetic-boot")
        check(identity?.startTime == 1_800_000_000_123_456, "unprivileged lifetime decoding does not exclude other users")
        check(ProcessLifetimeReader.identity(info: info, pid: 43, bootSession: "synthetic-boot") == nil, "lifetime decoding verifies the requested PID")
        info.kp_proc.p_un.__p_starttime.tv_usec = -1
        check(ProcessLifetimeReader.identity(info: info, pid: 42, bootSession: "synthetic-boot") == nil, "invalid lifetime timestamps are not invented")
        let own = ProcessLifetimeReader.read(pid: getpid(), bootSession: "synthetic-check-boot")
        check(own?.pid == getpid() && (own?.startTime ?? 0) > 0, "the native KERN_PROC_PID reader identifies the synthetic checks process")
    }

    private static func checkActivityStore(
        initial: ActivitySnapshot, process: ActivityProcessDescriptor, start: Date
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("killswitch-history-check-\(UUID().uuidString)", isDirectory: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { check(false, "remove temporary history: \(error.localizedDescription)") }
        }

        do {
            let url = directory.appendingPathComponent("activity.sqlite")
            var store: ActivityHistoryStore? = try ActivityHistoryStore(url: url)
            try store?.save(initial, now: start)
            try store?.save(ActivitySnapshot(
                date: start.addingTimeInterval(60), system: ActivityValues(cpu: 50),
                processes: [ActivityProcessSample(process: process, values: ActivityValues(cpu: nil, memory: 500))]
            ), now: start.addingTimeInterval(60))
            store = nil

            let reopened = try ActivityHistoryStore(url: url)
            let global = try reopened.history(process: nil, since: start, until: start.addingTimeInterval(60))
            check(global.map(\.values.cpu) == [10, 50], "system history survives closing and reopening")
            let perProcess = try reopened.history(
                process: process.identity, since: start, until: start.addingTimeInterval(60)
            )
            check(perProcess.count == 2, "per-process history survives restarts")
            check(perProcess.last?.values.cpu == nil, "SQLite preserves unavailable values")
            check(perProcess.last?.values.memory == 500, "SQLite preserves process measurements")
            let descriptors = try reopened.processes(since: start)
            check(descriptors == [process], "history keeps exited process descriptors")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "history database is private")
            for suffix in ["-wal", "-shm"] {
                let sidecar = url.path + suffix
                if FileManager.default.fileExists(atPath: sidecar) {
                    let attributes = try FileManager.default.attributesOfItem(atPath: sidecar)
                    check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "SQLite \(suffix) storage is private")
                }
            }

            try reopened.clear()
            check(try reopened.processes(since: .distantPast).isEmpty, "clear history removes process names")
            check(
                try reopened.history(process: nil, since: .distantPast, until: .distantFuture).isEmpty,
                "clear history removes system measurements"
            )
            try reopened.save(initial, now: start)

            try reopened.prune(now: start.addingTimeInterval(86_461))
            check(
                try reopened.history(process: nil, since: .distantPast, until: .distantFuture).isEmpty,
                "history older than 24 hours is deleted"
            )
            check(try reopened.processes(since: .distantPast).isEmpty, "expired process names are deleted")

            let link = directory.appendingPathComponent("linked.sqlite")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            do {
                _ = try ActivityHistoryStore(url: link)
                check(false, "history refuses a symlink database")
            } catch {
                check(true, "history refuses a symlink database")
            }
            try checkHistoryMigration(directory: directory, start: start)
        } catch {
            check(false, "activity history store: \(error.localizedDescription)")
        }
    }

    private static func checkHistoryMigration(directory: URL, start: Date) throws {
        let url = directory.appendingPathComponent("legacy.sqlite")
        let result = try CommandRunner.run("/usr/bin/sqlite3", arguments: [url.path, """
            CREATE TABLE samples (
                process TEXT NOT NULL, time REAL NOT NULL, cpu REAL, memory REAL,
                disk_read REAL, disk_written REAL, received REAL, sent REAL,
                PRIMARY KEY (process, time)
            );
            INSERT INTO samples VALUES('', \(start.timeIntervalSince1970), 25, 100, NULL, NULL, NULL, NULL);
            PRAGMA user_version = 1;
            """])
        guard result.succeeded else {
            check(false, "create synthetic legacy history schema: \(result.standardError)")
            return
        }
        do {
            let migrated = try ActivityHistoryStore(url: url)
            let points = try migrated.history(process: nil, since: start, until: start.addingTimeInterval(60))
            check(points.first?.values.cpu == 25, "history schema migration preserves earlier CPU measurements")
            check(points.first?.values.cpuSystem == nil, "migration does not invent a CPU breakdown")
            try migrated.save(ActivitySnapshot(
                date: start.addingTimeInterval(60),
                system: ActivityValues(cpu: 70, cpuSystem: 20, cpuUser: 50), processes: []
            ), now: start.addingTimeInterval(60))
            let latest = try migrated.history(process: nil, since: start, until: start.addingTimeInterval(60)).last
            check(latest?.values.cpuSystem == 20 && latest?.values.cpuUser == 50, "migrated history stores new CPU breakdowns")
        }
        let newer = try CommandRunner.run("/usr/bin/sqlite3", arguments: [url.path, "PRAGMA user_version = 99;"])
        guard newer.succeeded else {
            check(false, "prepare synthetic future schema")
            return
        }
        do {
            _ = try ActivityHistoryStore(url: url)
            check(false, "unknown history schema versions must not be overwritten")
        } catch { check(true, "unknown history schema versions must not be overwritten") }
    }
}
