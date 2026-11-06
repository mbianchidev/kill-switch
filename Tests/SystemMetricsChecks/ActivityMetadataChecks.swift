import Foundation
import InstallCore
import SystemMetricsCore

extension SystemMetricsChecks {
    static func checkPruningMetadataWrites() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func process(_ pid: Int32, _ name: String, user: String = "sample-user") -> ActivityProcessDescriptor {
            ActivityProcessDescriptor(
                identity: ActivityProcessIdentity(bootSession: "synthetic-metadata-boot", pid: pid, startTime: 100),
                name: name, user: user
            )
        }
        func inventory(for processes: [ActivityProcessDescriptor]) -> ActivityProcessInventory {
            var presence = Dictionary(uniqueKeysWithValues: (Int32(101)...107).map { ($0, ProcessLifetimePresence.absent) })
            for process in processes { presence[process.id.pid] = .present(process.id) }
            return ActivityProcessInventory(presence)
        }
        let expiring = process(101, "First expired worker")
        let nextExpiring = process(102, "Second expired worker")
        let original = process(103, "Original live worker")
        let updated = process(103, "Updated live worker", user: "updated-user")
        let unchanged = process(104, "Unchanged live worker")
        let closing = process(105, "Newly exited worker")
        let unsampled = process(106, "Inventory-only worker")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/followup-metadata/fixture-\(UUID().uuidString)", isDirectory: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { check(false, "remove synthetic metadata fixture: \(error.localizedDescription)") }
        }

        do {
            let url = directory.appendingPathComponent("activity.sqlite")
            let store = try ActivityHistoryStore(url: url)
            var catalog = ActivityProcessCatalog()
            var buffer = ActivityWriteBuffer()
            func observe(_ processes: [ActivityProcessDescriptor], now: Date) {
                catalog.observe(processes, inventory: inventory(for: processes), now: now)
            }
            let initial = [expiring, nextExpiring, original, unchanged, closing]
            observe(initial, now: start)
            try store.save(ActivitySnapshot(
                date: start, system: ActivityValues(cpu: 10),
                processes: initial.map { ActivityProcessSample(process: $0, values: ActivityValues(cpu: 20)) }
            ), now: start, processRecords: catalog.pendingRecords)
            catalog.markPersisted()
            observe([nextExpiring, original, unchanged, closing], now: start.addingTimeInterval(6))
            observe([original, unchanged, closing], now: start.addingTimeInterval(12))
            try store.save(ActivitySnapshot(
                date: start.addingTimeInterval(12), system: ActivityValues(cpu: 30), processes: []
            ), now: start.addingTimeInterval(12), processRecords: catalog.pendingRecords)
            catalog.markPersisted()
            try metadataSQL("""
                CREATE TABLE metadata_writes (key TEXT NOT NULL);
                CREATE TRIGGER audit_metadata_insert AFTER INSERT ON processes
                BEGIN INSERT INTO metadata_writes VALUES(NEW.key); END;
                CREATE TRIGGER audit_metadata_update AFTER UPDATE ON processes
                BEGIN INSERT INTO metadata_writes VALUES(NEW.key); END;
                """, at: url)

            func pruneOnly(now: Date) throws {
                try buffer.flush(processCatalog: &catalog) { snapshot, records in
                    try store.save(snapshot, now: now, processRecords: records)
                }
                let records = catalog.pendingTerminationRecords
                try store.prune(now: now, processRecords: records)
                catalog.markPersisted(records)
            }

            let firstPrune = start.addingTimeInterval(6 + ActivityProcessCatalog.terminatedRetention)
            observe([updated, unchanged, unsampled], now: firstPrune)
            check(catalog.needsPruning, "an expiry requests pruning between completed minute buckets")
            check(
                buffer.count == 0 && !catalog.pendingRecords.isEmpty,
                "a pruning-only flush starts with no measurements but dirty live and termination metadata"
            )
            try pruneOnly(now: firstPrune)
            check(
                try metadataWriteKeys(at: url) == [closing.id.key],
                "pruning-only writes termination changes without upserting either changed or unchanged live inventory"
            )
            check(
                Set(catalog.pendingRecords.map(\.process.id)) == Set([updated.id, unchanged.id, unsampled.id]),
                "successful pruning preserves every pending live descriptor for the next minute save"
            )
            check(!catalog.needsPruning, "successful pruning acknowledges the completed pruning request")
            let firstRecords = try store.processRecords(since: start)
            check(!firstRecords.contains { $0.process.id == expiring.id }, "pruning deletes the expired lifetime")
            check(
                firstRecords.first { $0.process.id == closing.id }?.terminatedAt == firstPrune,
                "pruning persists the new exit deadline"
            )
            check(
                firstRecords.first { $0.process.id == original.id }?.process == original,
                "live metadata waits for a minute save instead of being rewritten during pruning"
            )
            check(
                !firstRecords.contains { $0.process.id == unsampled.id },
                "pruning does not insert a newly observed live lifetime without measurements"
            )

            let secondPrune = firstPrune.addingTimeInterval(6)
            observe([updated, unchanged], now: secondPrune)
            let pendingBeforeFailure = Dictionary(uniqueKeysWithValues: catalog.pendingRecords.map { ($0.process.id, $0) })
            try metadataSQL("""
                DELETE FROM metadata_writes;
                CREATE TRIGGER reject_metadata_pruning BEFORE DELETE ON processes
                WHEN OLD.key = '\(nextExpiring.id.key)'
                BEGIN SELECT RAISE(FAIL, 'synthetic metadata pruning failure'); END;
                """, at: url)
            do {
                try pruneOnly(now: secondPrune)
                check(false, "synthetic pruning failures must propagate")
            } catch {
                check(
                    catalog.needsPruning
                        && Dictionary(uniqueKeysWithValues: catalog.pendingRecords.map { ($0.process.id, $0) }) == pendingBeforeFailure,
                    "failed pruning preserves pending termination and live changes for retry"
                )
                check(try metadataWriteKeys(at: url).isEmpty, "failed pruning rolls back metadata writes and audit entries")
                let failedRecords = try store.processRecords(since: start)
                check(
                    failedRecords.contains { $0.process.id == nextExpiring.id }
                        && !failedRecords.contains { $0.process.id == unsampled.id },
                    "failed pruning does not partially delete or insert process metadata"
                )
            }
            try metadataSQL("DROP TRIGGER reject_metadata_pruning;", at: url)
            try pruneOnly(now: secondPrune)
            check(
                try metadataWriteKeys(at: url) == [unsampled.id.key],
                "a pruning retry writes only the remaining unacknowledged termination record"
            )
            check(
                Set(catalog.pendingRecords.map(\.process.id)) == Set([updated.id, unchanged.id]),
                "a successful pruning retry still leaves dirty live metadata pending"
            )
            let retriedRecords = try store.processRecords(since: start)
            check(
                retriedRecords.first { $0.process.id == unsampled.id }?.terminatedAt == secondPrune,
                "pruning persists an exited inventory-only lifetime even without a measurement bucket"
            )
            check(
                !retriedRecords.contains { $0.process.id == nextExpiring.id },
                "pruning retry removes the second expired lifetime"
            )

            let metadataOnly = process(107, "New live inventory-only worker")
            let minuteSave = secondPrune.addingTimeInterval(6)
            observe([updated, metadataOnly], now: minuteSave)
            let minuteRecords = catalog.pendingRecords
            buffer.append(ActivitySnapshot(
                date: secondPrune, system: ActivityValues(cpu: 40),
                processes: [ActivityProcessSample(process: original, values: ActivityValues(cpu: 50))]
            ), now: minuteSave)
            try metadataSQL("DELETE FROM metadata_writes;", at: url)
            try buffer.flush(processCatalog: &catalog) { snapshot, records in
                try store.save(snapshot, now: minuteSave, processRecords: records)
            }
            let savedRecords = Dictionary(uniqueKeysWithValues: try store.processRecords(since: start).map { ($0.process.id, $0) })
            check(
                minuteRecords.allSatisfy { savedRecords[$0.process.id] == $0 },
                "a normal minute save persists all pending live metadata and termination deadlines"
            )
            check(
                try metadataWriteKeys(at: url) == minuteRecords.map(\.process.id.key).sorted(),
                "a minute save writes each pending record once without rewriting acknowledged exits"
            )
            check(
                savedRecords[updated.id]?.process == updated && savedRecords[updated.id]?.lastSeen == minuteSave,
                "newer live descriptors survive an older completed bucket's name and timestamp"
            )
            check(
                savedRecords[metadataOnly.id]?.process == metadataOnly,
                "a minute save includes live inventory metadata missing from its measurement bucket"
            )
            check(
                catalog.pendingRecords.isEmpty && !catalog.needsPruning && buffer.count == 0,
                "successful minute persistence clears the full pending metadata and measurement bucket"
            )
        } catch {
            check(false, "synthetic pruning metadata writes: \(error.localizedDescription)")
        }

        var changedAfterSelection = ActivityProcessCatalog()
        changedAfterSelection.observe([original], inventory: inventory(for: [original]), now: start)
        changedAfterSelection.observe([], inventory: inventory(for: []), now: start.addingTimeInterval(6))
        let persistedRecords = changedAfterSelection.pendingTerminationRecords
        changedAfterSelection.observe([updated], inventory: inventory(for: [updated]), now: start.addingTimeInterval(12))
        changedAfterSelection.markPersisted(persistedRecords)
        check(
            changedAfterSelection.pendingRecords == [
                ActivityProcessRecord(process: updated, lastSeen: start.addingTimeInterval(12))
            ] && persistedRecords.first?.terminatedAt != nil,
            "acknowledging persisted records cannot discard a newer pending live version of the same lifetime"
        )
        checkQueuedMetadataWrites()
    }

    private static func checkQueuedMetadataWrites() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = ActivityProcessIdentity(bootSession: "synthetic-queued-metadata-boot", pid: 201, startTime: 100)
        let original = ActivityProcessDescriptor(identity: identity, name: "Original queued worker", user: "original-user")
        let queued = ActivityProcessDescriptor(identity: identity, name: "Later queued worker", user: "queued-user")
        let current = ActivityProcessDescriptor(identity: identity, name: "Current live worker", user: "current-user")
        let retried = ActivityProcessDescriptor(identity: identity, name: "Retry live worker", user: "retry-user")

        for failLaterSave in [false, true] {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build/followup-metadata/fixture-\(UUID().uuidString)", isDirectory: true)
            defer {
                do { try FileManager.default.removeItem(at: directory) }
                catch { check(false, "remove queued metadata fixture: \(error.localizedDescription)") }
            }

            do {
                let url = directory.appendingPathComponent("activity.sqlite")
                let store = try ActivityHistoryStore(url: url)
                var catalog = ActivityProcessCatalog()
                var buffer = ActivityWriteBuffer()
                for (index, process) in [original, queued, queued].enumerated() {
                    let date = start.addingTimeInterval(Double(index * 60))
                    catalog.observe([process], now: date)
                    buffer.append(ActivitySnapshot(
                        date: date, system: ActivityValues(cpu: Double(index + 1)),
                        processes: [ActivityProcessSample(process: process, values: ActivityValues(cpu: Double(index + 10)))]
                    ), now: date)
                }
                var now = start.addingTimeInterval(180)
                catalog.observe([current], now: now)
                var expectedRecords = [ActivityProcessRecord(process: current, lastSeen: now)]
                check(
                    buffer.count == 3 && catalog.pendingRecords == expectedRecords,
                    "recovery starts with three older measurement buckets and dirty current name/user metadata"
                )
                func drain() throws {
                    try buffer.flush(processCatalog: &catalog) { snapshot, records in
                        check(records == expectedRecords, "every queued save receives the same latest pending metadata snapshot")
                        try store.save(snapshot, now: now, processRecords: records)
                        let reopened = try ActivityHistoryStore(url: url)
                        var restarted = ActivityProcessCatalog()
                        restarted.restore(try reopened.processRecords(since: start))
                        check(
                            restarted.records[identity] == expectedRecords.first,
                            "restarting after each queued save preserves current name/user metadata instead of older bucket descriptors"
                        )
                    }
                }
                if failLaterSave {
                    try metadataSQL("""
                        CREATE TRIGGER reject_later_bucket BEFORE INSERT ON samples
                        WHEN NEW.process = '' AND NEW.time = \(start.addingTimeInterval(60).timeIntervalSince1970)
                        BEGIN SELECT RAISE(FAIL, 'synthetic later bucket failure'); END;
                        """, at: url)
                    do {
                        try drain()
                        check(false, "a later queued save failure must propagate")
                    } catch {
                        check(
                            buffer.count == 2 && catalog.pendingRecords == expectedRecords,
                            "a later save failure leaves the unsaved buckets and all dirty metadata pending for retry"
                        )
                        check(
                            try store.history(process: nil, since: start, until: now).map(\.values.cpu) == [1],
                            "a later transaction failure preserves the first committed bucket without partially writing the failed one"
                        )
                    }
                    try metadataSQL("DROP TRIGGER reject_later_bucket;", at: url)
                    now = now.addingTimeInterval(6)
                    catalog.observe([retried], now: now)
                    expectedRecords = [ActivityProcessRecord(process: retried, lastSeen: now)]
                    check(
                        !catalog.pendingRecords.isEmpty && catalog.pendingRecords == expectedRecords,
                        "retry selects newly updated live metadata rather than the previous drain's version"
                    )
                }
                try drain()
                check(
                    buffer.count == 0 && catalog.pendingRecords.isEmpty && !catalog.needsPruning,
                    "a fully successful drain acknowledges its pending metadata and every queued measurement"
                )
                check(
                    try store.history(process: nil, since: start, until: now).map(\.values.cpu) == [1, 2, 3],
                    "recovery retains every system bucket across success or a partial-drain retry"
                )
                check(
                    try store.history(process: identity, since: start, until: now).map(\.values.cpu) == [10, 11, 12],
                    "recovery retains every process measurement without replacing its current descriptor"
                )
            } catch {
                check(false, "queued metadata persistence: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private static func metadataSQL(_ sql: String, at url: URL) throws -> String {
        let result = try CommandRunner.run("/usr/bin/sqlite3", arguments: [url.path, sql])
        guard result.succeeded else {
            throw ActivityHistoryError(message: "synthetic metadata SQL: \(result.standardError)")
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func metadataWriteKeys(at url: URL) throws -> [String] {
        try metadataSQL("SELECT key FROM metadata_writes ORDER BY key;", at: url)
            .split(separator: "\n").map(String.init)
    }
}
