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
        checkActivityProcessRetention(start: start, process: process)
        checkProcessInventoryRetention(start: start, process: process)
        checkPruningMetadataWrites()
        checkClearingActivityHistory()
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
        var catalog = ActivityProcessCatalog()
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
                catalog.observe(snapshot.processes.map(\.process), now: snapshot.date)
            }
        }
        check(history.snapshots.count == 51, "two synthetic hours with 5,000 processes retain only five live minutes")
        check(history.snapshots.last?.processes.count == 5_000, "memory bounds do not drop processes")
        check(accumulator.current?.processes.count == 5_000, "minute averages still include every synthetic process")
        check(
            catalog.processes.count == 5_000,
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
        var catalog = ActivityProcessCatalog()
        let brief = ActivitySnapshot(
            date: start, system: ActivityValues(),
            processes: [ActivityProcessSample(process: process, values: ActivityValues(cpu: 1))]
        )
        let exited = ActivitySnapshot(
            date: start.addingTimeInterval(0.1), system: ActivityValues(), processes: []
        )
        history.append(brief)
        _ = accumulator.append(brief)
        catalog.observe(brief.processes.map(\.process), now: brief.date)
        history.append(exited)
        _ = accumulator.append(exited)
        catalog.observe([], inventory: ActivityProcessInventory([process.id.pid: .absent]), now: exited.date)
        check(history.snapshots.last?.processes.isEmpty == true, "rapid refresh can replace a short-lived process measurement")
        check(
            catalog.processes == [process],
            "a coalesced short-lived process keeps its selector name and lifetime identity in the current minute"
        )

        let resumed = ActivitySnapshot(
            date: start.addingTimeInterval(6 * 3_600), system: ActivityValues(), processes: []
        )
        history.append(resumed)
        if let completed = accumulator.append(resumed) { pending.append(completed, now: resumed.date) }
        catalog.observe([], inventory: ActivityProcessInventory([process.id.pid: .absent]), now: resumed.date)
        check(pending.count == 1, "the pre-sleep minute remains queued until persistence succeeds")
        check(
            catalog.processes == [process],
            "descriptors awaiting persistence remain selectable even after the live window expires"
        )
        do {
            try pending.flush { _ in throw ActivityHistoryError(message: "synthetic catalog storage failure") }
            check(false, "synthetic selector persistence failure must propagate")
        } catch {
            check(
                catalog.processes == [process],
                "storage failure does not hide a queued process name"
            )
        }
        do {
            var archived: [ActivityProcessDescriptor] = []
            try pending.flush { archived.append(contentsOf: $0.processes.map(\.process)) }
            check(
                archived == [process] && catalog.processes == [process],
                "successful persistence hands process descriptors to the archive without losing selection"
            )
        } catch { check(false, "persist synthetic selector descriptors: \(error.localizedDescription)") }
        history.removeAll()
        accumulator = ActivityAccumulator()
        pending = ActivityWriteBuffer()
        catalog = ActivityProcessCatalog()
        check(
            catalog.processes.isEmpty,
            "clear history releases selector descriptors along with measurements"
        )
    }

    private static func checkActivityProcessRetention(start: Date, process: ActivityProcessDescriptor) {
        var catalog = ActivityProcessCatalog()
        catalog.observe([process], now: start)
        let terminatedAt = start.addingTimeInterval(6)
        catalog.observe([], inventory: ActivityProcessInventory([process.id.pid: .absent]), now: terminatedAt)
        catalog.prune(now: terminatedAt.addingTimeInterval(21_599))
        check(catalog.processes == [process], "an exited process remains selectable until six hours after its observed exit")
        catalog.prune(now: terminatedAt.addingTimeInterval(21_600))
        check(catalog.processes.isEmpty, "an exited process is removed exactly six hours after its observed exit")
        check(catalog.needsPruning, "process expiry requests persistent pruning even without a completed minute")
        check(
            catalog.pendingRecords.first?.terminatedAt == terminatedAt,
            "repeated absent samples do not move the original termination time"
        )
        let oldSnapshot = ActivitySnapshot(
            date: start, system: ActivityValues(cpu: 10),
            processes: [ActivityProcessSample(process: process, values: ActivityValues(cpu: 20))]
        )
        let retained = catalog.retainingProcesses(in: oldSnapshot)
        check(retained.processes.isEmpty && retained.system.cpu == 10, "late pre-sleep writes cannot restore expired processes or erase global history")
        catalog.restore([ActivityProcessRecord(process: process, lastSeen: start)])
        check(catalog.processes.isEmpty, "reopening storage cannot restore an expired process awaiting persistent deletion")
        catalog.markPersisted()
        check(catalog.pendingRecords.isEmpty && !catalog.needsPruning, "successful persistence acknowledges process changes")

        var active = ActivityProcessCatalog()
        active.observe([process], now: start)
        active.prune(now: start.addingTimeInterval(21_600))
        check(active.processes == [process], "collector failures cannot turn an unconfirmed live process into an expired one")
        let muchLater = start.addingTimeInterval(86_400)
        active.observe([process], now: muchLater)
        check(active.processes == [process], "old or idle processes are retained while their lifetime is still present")
        check(active.records[process.id]?.terminatedAt == nil, "a monitoring gap is not proof of process termination")
        active.observe(
            [], inventory: ActivityProcessInventory([process.id.pid: .absent]), now: muchLater.addingTimeInterval(6)
        )
        check(active.processes == [process], "the six-hour clock starts at exit rather than process creation or an old measurement")

        let replacement = ActivityProcessDescriptor(
            identity: ActivityProcessIdentity(
                bootSession: process.id.bootSession, pid: process.id.pid, startTime: process.id.startTime + 1
            ),
            name: "Replacement worker", user: "sample-user"
        )
        var reused = ActivityProcessCatalog()
        reused.observe([process], now: start)
        reused.observe([replacement], now: terminatedAt)
        reused.observe([replacement], now: terminatedAt.addingTimeInterval(21_600))
        check(reused.processes == [replacement], "expiry of an exited lifetime does not remove a replacement sharing its PID")

        var restored = ActivityProcessCatalog()
        restored.restore([
            ActivityProcessRecord(process: process, lastSeen: start, terminatedAt: terminatedAt),
            ActivityProcessRecord(process: replacement, lastSeen: start)
        ])
        restored.observe([replacement], now: terminatedAt.addingTimeInterval(21_599))
        check(restored.records[process.id]?.terminatedAt == terminatedAt, "restarts preserve a recorded exit deadline")
        check(restored.records[replacement.id]?.terminatedAt == nil, "reconciliation preserves a confirmed live process after an offline gap")
        restored.observe([replacement], now: terminatedAt.addingTimeInterval(21_600))
        check(restored.processes == [replacement], "an app restart does not grant exited processes another six hours")

        var offlineExit = ActivityProcessCatalog()
        offlineExit.restore([ActivityProcessRecord(process: process, lastSeen: start)])
        offlineExit.observe(
            [], inventory: ActivityProcessInventory([process.id.pid: .absent]), now: start.addingTimeInterval(21_600)
        )
        check(offlineExit.processes.isEmpty, "an exit while the app was closed ages from the last observed presence")

        var unpersisted = ActivityProcessCatalog()
        unpersisted.observe([process], now: start)
        unpersisted.observe([], inventory: ActivityProcessInventory([process.id.pid: .absent]), now: terminatedAt)
        let unsavedRecord = ActivityProcessRecord(process: process, lastSeen: start, terminatedAt: terminatedAt)
        check(unpersisted.pendingRecords == [unsavedRecord], "a never-persisted catalog starts with pending termination metadata")
        let pendingCutoff = start.addingTimeInterval(ActivityHistoryStore.retention)
        unpersisted.prune(now: pendingCutoff.addingTimeInterval(-1))
        check(unpersisted.pendingRecords == [unsavedRecord], "unsaved process metadata is still pending just before the 24-hour cutoff")
        unpersisted.prune(now: pendingCutoff)
        check(unpersisted.pendingRecords == [unsavedRecord], "unsaved process metadata is still pending exactly at the inclusive 24-hour cutoff")
        unpersisted.prune(now: pendingCutoff.addingTimeInterval(1))
        check(unpersisted.pendingRecords.isEmpty, "unsaved process metadata is removed strictly after the 24-hour cutoff")
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
        info.kp_proc.p_stat = Int8(SZOMB)
        check(ProcessLifetimeReader.identity(info: info, pid: 42, bootSession: "synthetic-boot") == nil, "native sampling does not treat defunct processes as live lifetimes")
        info.kp_proc.p_stat = Int8(SSLEEP)
        check(ProcessLifetimeReader.identity(info: info, pid: 42, bootSession: "synthetic-boot") == identity, "sleeping processes keep their live lifetime identity")
        info.kp_proc.p_un.__p_starttime.tv_usec = -1
        check(ProcessLifetimeReader.identity(info: info, pid: 42, bootSession: "synthetic-boot") == nil, "invalid lifetime timestamps are not invented")
        let own = ProcessLifetimeReader.read(pid: getpid(), bootSession: "synthetic-check-boot")
        check(own?.pid == getpid() && (own?.startTime ?? 0) > 0, "the native KERN_PROC_PID reader identifies the synthetic checks process")
    }

    private static func checkProcessInventoryRetention(start: Date, process: ActivityProcessDescriptor) {
        let unknown = ActivityProcessInventory([process.id.pid: .unavailable])
        let present = ActivityProcessInventory([process.id.pid: .present(process.id)])
        let absent = ActivityProcessInventory([process.id.pid: .absent])
        let defunct = ActivityProcessInventory([process.id.pid: .defunct])
        let resumed = start.addingTimeInterval(7 * 3_600)
        let confirmedExit = ActivityProcessDescriptor(
            identity: ActivityProcessIdentity(bootSession: process.id.bootSession, pid: process.id.pid + 1, startTime: 300),
            name: "Confirmed exited worker", user: "sample-user"
        )
        var restored = ActivityProcessCatalog()
        restored.restore([
            ActivityProcessRecord(process: process, lastSeen: start),
            ActivityProcessRecord(process: confirmedExit, lastSeen: start, terminatedAt: start.addingTimeInterval(6))
        ])
        restored.observe([], inventory: unknown, now: resumed)
        check(restored.processes == [process], "an unreadable restored lifetime remains selectable while confirmed exits are pruned")
        check(restored.records[process.id]?.lastSeen == start, "unknown reads do not invent a new last-seen timestamp")
        check(restored.records[process.id]?.terminatedAt == nil, "a successful resource sample with an unreadable identity does not confirm an offline exit")
        restored.observe([], now: resumed.addingTimeInterval(6))
        restored.observe([], inventory: unknown, now: resumed.addingTimeInterval(12))
        check(restored.processes == [process], "repeated omitted or unavailable lifetime reads preserve the unresolved restored lifetime")
        restored.observe([], inventory: absent, now: resumed.addingTimeInterval(18))
        check(restored.processes.isEmpty, "confirmed absence eventually expires an unresolved offline lifetime")
        check(restored.pendingRecords.first { $0.process.id == process.id }?.terminatedAt == start, "unknown retries do not lose the restored lifetime's original offline exit deadline")

        var readable = ActivityProcessCatalog()
        readable.restore([ActivityProcessRecord(process: process, lastSeen: start)])
        readable.observe([], inventory: present, now: resumed)
        check(readable.processes == [process] && readable.records[process.id]?.lastSeen == resumed, "a readable matching lifetime stays live without a resource measurement")
        let observedExit = resumed.addingTimeInterval(6)
        readable.observe([], inventory: absent, now: observedExit)
        readable.observe([], inventory: defunct, now: observedExit.addingTimeInterval(6))
        readable.observe([], inventory: unknown, now: observedExit.addingTimeInterval(12))
        check(readable.records[process.id]?.terminatedAt == observedExit, "a verified live reconciliation clears the offline marker and repeated exit states do not extend its deadline")
        readable.observe([], inventory: unknown, now: observedExit.addingTimeInterval(21_600))
        check(readable.processes.isEmpty, "confirmed exits still reach their six-hour deadline during identity failures")

        let replacement = ActivityProcessDescriptor(
            identity: ActivityProcessIdentity(
                bootSession: process.id.bootSession, pid: process.id.pid, startTime: process.id.startTime + 1
            ),
            name: "Verified replacement", user: "sample-user"
        )
        var replaced = ActivityProcessCatalog()
        replaced.restore([ActivityProcessRecord(process: process, lastSeen: start)])
        replaced.observe([], inventory: unknown, now: resumed)
        replaced.observe([replacement], now: resumed.addingTimeInterval(6))
        check(replaced.processes == [replacement], "a verified replacement confirms only the prior same-PID lifetime's offline exit")
        var zombie = ActivityProcessCatalog()
        zombie.restore([ActivityProcessRecord(process: process, lastSeen: start)])
        zombie.observe([process], inventory: defunct, now: resumed)
        check(zombie.processes.isEmpty, "a verified defunct PID cannot be revived by a stale resource descriptor")

        let afterDay = start.addingTimeInterval(ActivityHistoryStore.retention + 1)
        var interrupted = ActivityProcessCatalog()
        interrupted.observe([process], now: start)
        interrupted.prune(now: afterDay)
        interrupted.observe([], inventory: unknown, now: afterDay.addingTimeInterval(6))
        check(interrupted.processes == [process], "the 24-hour cutoff does not expire an unconfirmed lifetime during collector failures")
        interrupted.observe([], inventory: absent, now: afterDay.addingTimeInterval(12))
        check(interrupted.processes.isEmpty && interrupted.needsPruning, "a confirmed exit after a gap over 24 hours expires immediately with its SQLite history")
        let record = ActivityProcessRecord(
            process: process, lastSeen: start, terminatedAt: start.addingTimeInterval(ActivityHistoryStore.retention)
        )
        check(!record.isExpired(now: start.addingTimeInterval(86_400)), "confirmed-exit history is retained exactly at SQLite's inclusive 24-hour boundary")
        check(record.isExpired(now: afterDay), "confirmed-exit history expires strictly beyond SQLite's 24-hour boundary even before six hours")
        var unresolved = ActivityProcessCatalog()
        unresolved.restore([ActivityProcessRecord(process: process, lastSeen: start)])
        unresolved.observe([], inventory: unknown, now: afterDay)
        unresolved.observe([], inventory: unknown, now: afterDay.addingTimeInterval(6))
        check(unresolved.processes == [process], "repeated unknown reads preserve restored lifetimes even beyond the normal history window")

        let wrongPID = ActivityProcessInventory([process.id.pid + 1: .present(process.id)])
        check(wrongPID[process.id.pid + 1] == .unavailable, "a mismatched inventory PID cannot verify presence or a replacement")
        check(ActivityProcessInventory()[process.id.pid] == .unavailable, "omitted inventory PIDs remain unknown rather than absent")
        check(ActivityProcessInventory(processes: [process, replacement])[process.id.pid] == .unavailable, "conflicting same-PID descriptors do not invent a verified lifetime")
        checkLifetimePresenceDecoding(process: process)
    }

    private static func checkLifetimePresenceDecoding(process: ActivityProcessDescriptor) {
        var info = kinfo_proc()
        info.kp_proc.p_pid = process.id.pid
        info.kp_proc.p_stat = Int8(SSLEEP)
        info.kp_proc.p_un.__p_starttime.tv_sec = 1_800_000_000
        info.kp_proc.p_un.__p_starttime.tv_usec = 123_456
        func decode(status: Int32 = 0, size: Int = MemoryLayout<kinfo_proc>.size, error: Int32 = 0) -> ProcessLifetimePresence {
            ProcessLifetimeReader.presence(
                info: info, pid: process.id.pid, bootSession: process.id.bootSession, status: status, size: size, error: error
            )
        }
        check(decode().identity?.startTime == 1_800_000_000_123_456, "matching readable lifetime presence remains distinct from missing resource counters")
        check(decode(size: 0) == .absent, "a successful empty KERN_PROC_PID response confirms absence")
        check(decode(status: -1, error: ESRCH) == .absent, "a no-such-process kernel error confirms absence")
        check(decode(status: -1, error: EPERM) == .unavailable, "a restricted lifetime read does not confirm absence")
        check(decode(status: -1, error: ENOMEM) == .unavailable, "a failed lifetime read with an unusable buffer remains unknown")
        check(decode(size: MemoryLayout<kinfo_proc>.size - 1) == .unavailable, "a truncated lifetime response does not confirm absence")
        info.kp_proc.p_pid += 1
        check(decode() == .unavailable, "a returned PID mismatch cannot verify a replacement")
        info.kp_proc.p_pid = process.id.pid
        info.kp_proc.p_stat = Int8(SZOMB)
        check(decode() == .defunct, "a verified zombie state confirms a defunct lifetime")
        info.kp_proc.p_stat = Int8(SSTOP)
        check(decode().identity != nil, "stopped processes remain present rather than defunct")
        info.kp_proc.p_un.__p_starttime.tv_usec = -1
        check(decode() == .unavailable, "an unreadable lifetime timestamp remains unavailable rather than absent")
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
            try checkTerminatedProcessStorage(directory: directory, initial: initial, process: process, start: start)
        } catch {
            check(false, "activity history store: \(error.localizedDescription)")
        }
    }

    private static func checkTerminatedProcessStorage(
        directory: URL, initial: ActivitySnapshot, process: ActivityProcessDescriptor, start: Date
    ) throws {
        let url = directory.appendingPathComponent("process-retention.sqlite")
        let replacement = ActivityProcessDescriptor(
            identity: ActivityProcessIdentity(
                bootSession: process.id.bootSession, pid: process.id.pid, startTime: process.id.startTime + 1
            ),
            name: "Replacement worker", user: "sample-user"
        )
        var catalog = ActivityProcessCatalog()
        catalog.observe([process], now: start)
        let terminatedAt = start.addingTimeInterval(6)
        do {
            let store = try ActivityHistoryStore(url: url)
            try store.save(initial, now: start, processRecords: catalog.pendingRecords)
            catalog.markPersisted()
            catalog.observe([replacement], now: terminatedAt)
            try store.save(ActivitySnapshot(
                date: terminatedAt, system: ActivityValues(cpu: 30),
                processes: [ActivityProcessSample(process: replacement, values: ActivityValues(cpu: 40))]
            ), now: terminatedAt, processRecords: catalog.pendingRecords)
        }

        let reopened = try ActivityHistoryStore(url: url)
        let records = try reopened.processRecords(since: start)
        check(records.first { $0.process.id == process.id }?.terminatedAt == terminatedAt, "SQLite preserves the first observed termination across restarts")
        check(records.contains { $0.process.id == replacement.id && $0.terminatedAt == nil }, "SQLite does not mark a live replacement as terminated")
        let expiry = terminatedAt.addingTimeInterval(21_600)
        try reopened.prune(now: expiry.addingTimeInterval(-1))
        check(try reopened.processes(since: start).count == 2, "persistent process history is retained just before its six-hour exit deadline")

        var restored = ActivityProcessCatalog()
        restored.restore(records)
        restored.observe([replacement], now: expiry)
        let trigger = try CommandRunner.run("/usr/bin/sqlite3", arguments: [url.path, """
            CREATE TRIGGER reject_expiry BEFORE DELETE ON processes
            BEGIN SELECT RAISE(FAIL, 'synthetic deletion failure'); END;
            """])
        guard trigger.succeeded else {
            throw ActivityHistoryError(message: "create synthetic pruning failure: \(trigger.standardError)")
        }
        do {
            try reopened.prune(now: expiry, processRecords: restored.pendingRecords)
            check(false, "persistent expiry failures must be reported")
        } catch {
            check(
                try reopened.history(process: process.id, since: start, until: expiry).count == 1,
                "failed pruning rolls back measurement deletion together with process metadata"
            )
            check(try reopened.processes(since: start).count == 2, "failed pruning does not partly delete process records")
        }
        let drop = try CommandRunner.run("/usr/bin/sqlite3", arguments: [url.path, "DROP TRIGGER reject_expiry;"])
        guard drop.succeeded else {
            throw ActivityHistoryError(message: "remove synthetic pruning failure: \(drop.standardError)")
        }
        try reopened.prune(now: expiry, processRecords: restored.pendingRecords)
        restored.markPersisted()
        check(try reopened.processes(since: start) == [replacement], "persistent expiry deletes only the terminated lifetime at six hours")
        check(
            try reopened.history(process: process.id, since: start, until: expiry).isEmpty,
            "expiry deletes all saved measurements for the terminated process, not just its selector entry"
        )
        check(
            try reopened.history(process: replacement.id, since: start, until: expiry).count == 1,
            "live-process measurements older than six hours remain available"
        )
        check(
            try reopened.history(process: nil, since: start, until: expiry).map(\.values.cpu) == [10, 30],
            "process expiry preserves whole-Mac measurements within the 24-hour window"
        )
        try reopened.save(restored.retainingProcesses(in: initial), now: expiry)
        check(try reopened.processes(since: start) == [replacement], "a delayed bucket cannot reinsert an expired process")
        let secondReopen = try ActivityHistoryStore(url: url)
        check(try secondReopen.processes(since: start) == [replacement], "expired process removal survives another database reopen")
        try checkLongGapProcessStorage(directory: directory, initial: initial, process: process, start: start)
    }

    private static func checkLongGapProcessStorage(
        directory: URL, initial: ActivitySnapshot, process: ActivityProcessDescriptor, start: Date
    ) throws {
        let store = try ActivityHistoryStore(url: directory.appendingPathComponent("gap-retention.sqlite"))
        var catalog = ActivityProcessCatalog()
        catalog.observe([process], now: start)
        try store.save(initial, now: start, processRecords: catalog.pendingRecords)
        catalog.markPersisted()
        let boundary = start.addingTimeInterval(ActivityHistoryStore.retention)
        catalog.observe([], inventory: ActivityProcessInventory([process.id.pid: .absent]), now: boundary)
        try store.save(
            ActivitySnapshot(date: boundary, system: ActivityValues(cpu: 30), processes: []),
            now: boundary, processRecords: catalog.pendingRecords
        )
        catalog.markPersisted()
        let retainedProcesses = try store.processes(since: start)
        check(catalog.processes == [process] && retainedProcesses == [process], "the catalog and SQLite both retain a confirmed exit exactly at 24 hours")
        let beyondBoundary = boundary.addingTimeInterval(1)
        catalog.prune(now: beyondBoundary)
        try store.save(
            ActivitySnapshot(date: beyondBoundary, system: ActivityValues(cpu: 40), processes: []),
            now: beyondBoundary, processRecords: catalog.pendingRecords
        )
        let expiredProcesses = try store.processes(since: start)
        check(catalog.processes.isEmpty && expiredProcesses.isEmpty, "the catalog and SQLite both remove a confirmed exit once its last sighting exceeds 24 hours")
        check(try store.history(process: process.id, since: start, until: beyondBoundary).isEmpty, "long-gap confirmed-exit pruning removes the matching measurements")
        check(try store.history(process: nil, since: start, until: beyondBoundary).map(\.values.cpu) == [30, 40], "long-gap process pruning preserves available whole-Mac measurements")
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
        let versionTwoURL = directory.appendingPathComponent("version-two.sqlite")
        let versionTwo = try CommandRunner.run("/usr/bin/sqlite3", arguments: [versionTwoURL.path, """
            CREATE TABLE samples (
                process TEXT NOT NULL, time REAL NOT NULL, cpu REAL, memory REAL,
                disk_read REAL, disk_written REAL, received REAL, sent REAL, cpu_system REAL, cpu_user REAL,
                PRIMARY KEY (process, time)
            );
            CREATE TABLE processes (
                key TEXT PRIMARY KEY, boot TEXT NOT NULL, pid INTEGER NOT NULL,
                start TEXT NOT NULL, name TEXT NOT NULL, user TEXT NOT NULL, last_seen REAL NOT NULL
            );
            INSERT INTO processes VALUES('legacy-boot/91/100', 'legacy-boot', 91, '100', 'Live worker', 'sample-user', \(start.timeIntervalSince1970));
            INSERT INTO processes VALUES('legacy-boot/92/200', 'legacy-boot', 92, '200', 'Exited worker', 'sample-user', \(start.timeIntervalSince1970));
            INSERT INTO samples VALUES('legacy-boot/91/100', \(start.timeIntervalSince1970), 10, 100, NULL, NULL, NULL, NULL, NULL, NULL);
            INSERT INTO samples VALUES('legacy-boot/92/200', \(start.timeIntervalSince1970), 20, 200, NULL, NULL, NULL, NULL, NULL, NULL);
            PRAGMA user_version = 2;
            """])
        guard versionTwo.succeeded else {
            throw ActivityHistoryError(message: "create synthetic version-two history: \(versionTwo.standardError)")
        }
        let migratedProcesses = try ActivityHistoryStore(url: versionTwoURL)
        let legacyRecords = try migratedProcesses.processRecords(since: start)
        check(legacyRecords.count == 2 && legacyRecords.allSatisfy { $0.terminatedAt == nil }, "version-two migration preserves names without inventing exit times")
        guard let live = legacyRecords.first(where: { $0.process.id.pid == 91 })?.process,
              let exited = legacyRecords.first(where: { $0.process.id.pid == 92 })?.process else {
            throw ActivityHistoryError(message: "synthetic migration lost process descriptors.")
        }
        var catalog = ActivityProcessCatalog()
        catalog.restore(legacyRecords)
        let resumed = start.addingTimeInterval(21_600)
        catalog.observe(
            [live], inventory: ActivityProcessInventory([live.id.pid: .present(live.id), exited.id.pid: .absent]),
            now: resumed
        )
        try migratedProcesses.prune(now: resumed, processRecords: catalog.pendingRecords)
        check(try migratedProcesses.processes(since: start) == [live], "migration reconciles old exited processes without expiring a confirmed live process")
        check(
            try migratedProcesses.history(process: live.id, since: start, until: resumed).count == 1,
            "migration keeps the older measurements of a process that is still alive"
        )
        check(
            try migratedProcesses.history(process: exited.id, since: start, until: resumed).isEmpty,
            "migration removes an old exited process's measurements at the six-hour boundary"
        )
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
