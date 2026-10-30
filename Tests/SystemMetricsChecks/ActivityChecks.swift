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
