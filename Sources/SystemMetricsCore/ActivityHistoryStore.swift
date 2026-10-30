import CSQLite
import Foundation

public struct ActivityHistoryError: LocalizedError {
    public let message: String
    public var errorDescription: String? { "Activity history: \(message)" }
    public init(message: String) { self.message = message }
}

// Confine the store to the resource sampling queue.
public final class ActivityHistoryStore {
    public static let retention: TimeInterval = 86_400
    private var database: OpaquePointer?
    private enum Binding {
        case text(String)
        case number(Double)
        case null
    }

    public init(url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let directoryAttributes = try manager.attributesOfItem(atPath: directory.path)
        guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ActivityHistoryError(message: "refusing a linked or non-directory storage location.")
        }
        if manager.fileExists(atPath: url.path) || (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ActivityHistoryError(message: "refusing a linked or non-file database.")
            }
        } else {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ActivityHistoryError(message: "could not create the private database.")
            }
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure("open database")
            sqlite3_close(database)
            database = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(database, 2_000)
            var version: Int32 = 0
            try query("PRAGMA user_version") { version = sqlite3_column_int($0, 0) }
            guard (0...2).contains(version) else {
                throw ActivityHistoryError(message: "unsupported database version \(version); history was not changed.")
            }
            try execute("PRAGMA auto_vacuum = INCREMENTAL")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try execute("PRAGMA secure_delete = ON")
            if version == 1 {
                try execute("""
                    BEGIN IMMEDIATE;
                    ALTER TABLE samples ADD COLUMN cpu_system REAL;
                    ALTER TABLE samples ADD COLUMN cpu_user REAL;
                    PRAGMA user_version = 2;
                    COMMIT;
                    """)
            }
            try execute("""
                CREATE TABLE IF NOT EXISTS samples (
                    process TEXT NOT NULL, time REAL NOT NULL,
                    cpu REAL, memory REAL, disk_read REAL, disk_written REAL, received REAL, sent REAL,
                    cpu_system REAL, cpu_user REAL,
                    PRIMARY KEY (process, time)
                );
                CREATE INDEX IF NOT EXISTS samples_time ON samples(time);
                CREATE TABLE IF NOT EXISTS processes (
                    key TEXT PRIMARY KEY, boot TEXT NOT NULL, pid INTEGER NOT NULL,
                    start TEXT NOT NULL, name TEXT NOT NULL, user TEXT NOT NULL, last_seen REAL NOT NULL
                );
                PRAGMA user_version = 2;
                """)
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit {
        if sqlite3_close(database) != SQLITE_OK {
            fputs("KillSwitch could not close the activity history database.\n", stderr)
        }
    }

    public func save(_ snapshot: ActivitySnapshot, now: Date) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let timestamp = snapshot.date.timeIntervalSince1970
            try execute("DELETE FROM samples WHERE time = ?", bindings: [.number(timestamp)])
            try insert(values: snapshot.system, key: "", timestamp: timestamp)
            for sample in snapshot.processes {
                let process = sample.process
                try execute("""
                    INSERT INTO processes(key, boot, pid, start, name, user, last_seen) VALUES(?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET name = excluded.name, user = excluded.user,
                        last_seen = MAX(last_seen, excluded.last_seen)
                    """, bindings: [
                        .text(process.identity.key), .text(process.identity.bootSession),
                        .number(Double(process.identity.pid)), .text(String(process.identity.startTime)),
                        .text(process.name), .text(process.user), .number(timestamp)
                    ])
                try insert(values: sample.values, key: process.identity.key, timestamp: timestamp)
            }
            try deleteExpired(now: now)
            try execute("COMMIT")
        } catch {
            do { try execute("ROLLBACK") }
            catch { fputs("KillSwitch history rollback failed: \(error.localizedDescription)\n", stderr) }
            throw error
        }
    }

    public func prune(now: Date) throws {
        try deleteExpired(now: now)
        try execute("PRAGMA incremental_vacuum(64)")
    }

    public func history(
        process: ActivityProcessIdentity?, since: Date, until: Date
    ) throws -> [ActivityHistoryPoint] {
        var result: [ActivityHistoryPoint] = []
        try query("""
            SELECT time, cpu, memory, disk_read, disk_written, received, sent, cpu_system, cpu_user
            FROM samples WHERE process = ? AND time >= ? AND time <= ? ORDER BY time
            """, bindings: [
                .text(process?.key ?? ""), .number(since.timeIntervalSince1970), .number(until.timeIntervalSince1970)
            ]) { statement in
                let values = (1...8).map { index -> Double? in
                    sqlite3_column_type(statement, Int32(index)) == SQLITE_NULL
                        ? nil : sqlite3_column_double(statement, Int32(index))
                }
                result.append(ActivityHistoryPoint(
                    date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    values: ActivityValues(components: values)
                ))
            }
        return result
    }

    public func processes(since: Date) throws -> [ActivityProcessDescriptor] {
        var result: [ActivityProcessDescriptor] = []
        try query("""
            SELECT boot, pid, start, name, user FROM processes
            WHERE last_seen >= ? ORDER BY name COLLATE NOCASE, pid
            """, bindings: [.number(since.timeIntervalSince1970)]) { statement in
                guard let start = UInt64(text(statement, 2)) else {
                    throw ActivityHistoryError(message: "a saved process identity is invalid.")
                }
                result.append(ActivityProcessDescriptor(
                    identity: ActivityProcessIdentity(
                        bootSession: text(statement, 0), pid: sqlite3_column_int(statement, 1), startTime: start
                    ),
                    name: text(statement, 3), user: text(statement, 4)
                ))
            }
        return result
    }

    public func clear() throws {
        try execute("DELETE FROM samples; DELETE FROM processes; VACUUM; PRAGMA wal_checkpoint(TRUNCATE);")
    }

    private func deleteExpired(now: Date) throws {
        let cutoff = now.addingTimeInterval(-Self.retention).timeIntervalSince1970
        try execute("DELETE FROM samples WHERE time < ?", bindings: [.number(cutoff)])
        try execute("DELETE FROM processes WHERE last_seen < ?", bindings: [.number(cutoff)])
    }

    private func insert(values: ActivityValues, key: String, timestamp: Double) throws {
        try execute(
            "INSERT INTO samples VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            bindings: [.text(key), .number(timestamp)] + values.components.map {
                $0.map(Binding.number) ?? .null
            }
        )
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        if bindings.isEmpty {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure("write database") }
        } else {
            try query(sql, bindings: bindings) { _ in }
        }
    }

    private func query(
        _ sql: String, bindings: [Binding] = [], row: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure("prepare database operation")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch binding {
            case let .text(value):
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                status = sqlite3_bind_text(statement, index, value, -1, transient)
            case let .number(value): status = sqlite3_bind_double(statement, index, value)
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw failure("bind database value") }
        }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try row(statement)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure("read or write database") }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private func failure(_ operation: String) -> ActivityHistoryError {
        let detail = sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown SQLite error"
        return ActivityHistoryError(message: "could not \(operation): \(detail)")
    }
}
