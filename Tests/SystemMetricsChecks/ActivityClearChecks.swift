import Foundation
import SystemMetricsCore

extension SystemMetricsChecks {
    static func checkClearingActivityHistory() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func process(
            _ pid: Int32, _ name: String, startTime: UInt64 = 100, user: String = "sample-user"
        ) -> ActivityProcessDescriptor {
            ActivityProcessDescriptor(
                identity: ActivityProcessIdentity(
                    bootSession: "synthetic-clear-boot", pid: pid, startTime: startTime
                ),
                name: name, user: user
            )
        }
        let original = process(101, "Original worker")
        let live = process(101, "Current worker", user: "updated-user")
        let exited = process(102, "Exited worker")
        let oldLifetime = process(103, "Previous lifetime")
        let replacement = process(103, "Current replacement", startTime: 200)
        let unresolved = process(104, "Restored historical worker")
        let inventoryOnly = process(105, "Worker without current measurements")
        let initial = ActivitySnapshot(
            date: start, system: ActivityValues(cpu: 10),
            processes: [original, exited, oldLifetime, inventoryOnly].map {
                ActivityProcessSample(process: $0, values: ActivityValues(cpu: 20))
            }
        )
        let lastLive = ActivitySnapshot(
            date: start.addingTimeInterval(6), system: ActivityValues(cpu: 30),
            processes: [live, replacement].map {
                ActivityProcessSample(process: $0, values: ActivityValues(cpu: 40))
            }
        )
        var catalog = ActivityProcessCatalog()
        catalog.restore([ActivityProcessRecord(process: unresolved, lastSeen: start)])
        catalog.observe(initial.processes.map(\.process), now: initial.date)
        var history = ActivityLiveHistory()
        history.append(initial)
        history.append(lastLive)
        var accumulator = ActivityAccumulator()
        _ = accumulator.append(initial)
        _ = accumulator.append(lastLive)
        var buffer = ActivityWriteBuffer()
        buffer.append(initial, now: lastLive.date)

        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/followup-clear/fixture-\(UUID().uuidString)", isDirectory: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { check(false, "remove synthetic clear fixture: \(error.localizedDescription)") }
        }
        do {
            let store = try ActivityHistoryStore(url: directory.appendingPathComponent("activity.sqlite"))
            try store.save(initial, now: initial.date, processRecords: catalog.pendingRecords)
            catalog.markPersisted()
            catalog.observe(lastLive.processes.map(\.process), inventory: ActivityProcessInventory([
                live.id.pid: .present(live.id),
                exited.id.pid: .absent,
                replacement.id.pid: .present(replacement.id),
                unresolved.id.pid: .unavailable,
                inventoryOnly.id.pid: .present(inventoryOnly.id)
            ]), now: lastLive.date)
            check(
                catalog.records[exited.id]?.terminatedAt == lastLive.date
                    && catalog.records[oldLifetime.id]?.terminatedAt == lastLive.date
                    && catalog.pendingTerminationRecords.count == 2,
                "clear fixture includes unsaved exited and replaced lifetime names"
            )
            check(
                catalog.records[unresolved.id] != nil && catalog.records[inventoryOnly.id] != nil,
                "clear fixture includes historical entries absent from the current live table"
            )

            try store.clear()
            catalog.resetKeepingLiveProcesses()
            catalog.prune(now: lastLive.date.addingTimeInterval(90))
            history.removeAll()
            accumulator = ActivityAccumulator()
            buffer = ActivityWriteBuffer()

            let liveRecords = [
                ActivityProcessRecord(process: live, lastSeen: lastLive.date),
                ActivityProcessRecord(process: replacement, lastSeen: lastLive.date)
            ]
            check(
                Set(catalog.processes.map(\.id)) == Set([live.id, replacement.id]),
                "clearing history preserves exactly the currently displayed live lifetimes"
            )
            check(
                catalog.records[live.id]?.process == live,
                "clearing history preserves the latest live name and owner for the selector"
            )
            check(
                catalog.records[live.id] != nil && catalog.records[replacement.id] != nil,
                "a live selection remains valid and another displayed live row is immediately selectable"
            )
            check(
                catalog.records[exited.id] == nil && catalog.records[oldLifetime.id] == nil,
                "clearing history removes exited selections without confusing a replacement sharing its PID"
            )
            check(
                catalog.records[unresolved.id] == nil && catalog.records[inventoryOnly.id] == nil,
                "clearing history removes stale historical selections absent from the live table"
            )
            check(
                liveRecords.allSatisfy { catalog.records[$0.process.id] == $0 },
                "clearing history keeps actual last observation times without inventing a fresh sighting"
            )
            check(
                Dictionary(uniqueKeysWithValues: catalog.pendingRecords.map { ($0.process.id, $0) })
                    == Dictionary(uniqueKeysWithValues: liveRecords.map { ($0.process.id, $0) }),
                "clearing history discards old pending metadata and queues only the retained live descriptors"
            )
            check(
                catalog.pendingTerminationRecords.isEmpty && !catalog.needsPruning,
                "clearing history does not retain obsolete termination or pruning requests"
            )
            check(history.snapshots.isEmpty, "clearing history does not reinsert the last live measurement")
            check(accumulator.current == nil, "clearing history discards the unfinished minute")
            check(buffer.count == 0, "clearing history discards buffered storage retries")
            var writes = 0
            try buffer.flush { _ in writes += 1 }
            check(writes == 0, "a storage retry after clearing cannot resurrect buffered measurements")
            check(
                try store.processRecords(since: start).isEmpty,
                "clearing history deletes all stored historical names before new sampling"
            )
            let savedIdentities: [ActivityProcessIdentity?] = [nil, live.id, exited.id, oldLifetime.id, replacement.id]
            for identity in savedIdentities {
                check(
                    try store.history(process: identity, since: start, until: lastLive.date).isEmpty,
                    "clearing history deletes stored measurements for \(identity?.key ?? "Entire Mac")"
                )
            }

            let retained = catalog.records
            catalog.resetKeepingLiveProcesses()
            check(
                catalog.records == retained,
                "clearing twice before the next sample still preserves the displayed live lifetimes and timestamps"
            )

            let next = ActivitySnapshot(
                date: start.addingTimeInterval(12), system: ActivityValues(cpu: 50),
                processes: [ActivityProcessSample(process: live, values: ActivityValues(cpu: 60))]
            )
            history.append(next)
            _ = accumulator.append(next)
            catalog.observe(next.processes.map(\.process), now: next.date)
            check(
                history.snapshots == [next] && accumulator.current == next,
                "new sampling after clearing contains only new measurements"
            )
            try store.save(next, now: next.date, processRecords: catalog.pendingRecords)
            catalog.markPersisted()
            check(
                try store.history(process: nil, since: start, until: next.date) == [next.point(for: nil)],
                "new sampling does not restore cleared whole-Mac measurements"
            )
            check(
                try store.history(process: live.id, since: start, until: next.date) == [next.point(for: live.id)],
                "new sampling does not restore cleared per-process measurements"
            )
            check(
                Set(try store.processes(since: start).map(\.id)) == Set([live.id, replacement.id]),
                "persisting retained live metadata cannot restore historical process names"
            )
        } catch {
            check(false, "synthetic clear history checks: \(error.localizedDescription)")
        }

        var restoredOnly = ActivityProcessCatalog()
        restoredOnly.restore([ActivityProcessRecord(process: unresolved, lastSeen: start)])
        restoredOnly.resetKeepingLiveProcesses()
        check(
            restoredOnly.records.isEmpty && restoredOnly.pendingRecords.isEmpty,
            "clearing before any live sample does not retain restored historical names"
        )
        var emptyLive = ActivityProcessCatalog()
        emptyLive.observe([live], now: start)
        emptyLive.observe([], inventory: ActivityProcessInventory([live.id.pid: .present(live.id)]), now: lastLive.date)
        emptyLive.resetKeepingLiveProcesses()
        check(
            emptyLive.records.isEmpty && emptyLive.pendingRecords.isEmpty,
            "clearing an empty live table does not retain inventory-only historical descriptors"
        )
    }
}
