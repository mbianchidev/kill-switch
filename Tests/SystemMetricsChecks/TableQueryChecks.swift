import Foundation
import SystemMetricsCore
import TableQueryCore

private struct QueryFixture: Sendable {
    let id: String
    let name: String
    let pid: Int32
    let cpu: Double?
    let bytes: UInt64?
    let seconds: Double?
    let locked: Bool
    let modified: Date?
    let path: String
}

private enum QueryFields {
    static let name = TableField<QueryFixture>.text("name", title: "Process", aliases: ["command"]) { $0.name }
    static let pid = TableField<QueryFixture>.number("pid", title: "PID", searchable: true) { Decimal($0.pid) }
    static let cpu = TableField<QueryFixture>.number("cpu", title: "CPU %", aliases: ["CPU%"], unit: .percent) { $0.cpu }
    static let bytes = TableField<QueryFixture>.number("size", title: "Size", unit: .bytes) { $0.bytes.map(Decimal.init) }
    static let seconds = TableField<QueryFixture>.number("time", title: "CPU time", unit: .seconds) { $0.seconds }
    static let locked = TableField<QueryFixture>.boolean("locked", title: "Locked") { $0.locked }
    static let modified = TableField<QueryFixture>.date("modified", title: "Modified") { $0.modified }
    static let path = TableField<QueryFixture>.text("path", title: "Path") { $0.path }
    static let all = [name, pid, cpu, bytes, seconds, locked, modified, path]
}

extension SystemMetricsChecks {
    static func checkTableQueries() {
        let rows = [
            QueryFixture(
                id: "one", name: "Example worker 2", pid: 2, cpu: 40, bytes: 1_024, seconds: 60,
                locked: false, modified: Date(timeIntervalSince1970: 1_767_225_600), path: "/tmp/example one"
            ),
            QueryFixture(
                id: "two", name: "Example worker 10", pid: 10, cpu: 40.5, bytes: 1_073_741_824, seconds: 120,
                locked: true, modified: Date(timeIntervalSince1970: 1_767_312_000), path: "[::1]:8080"
            ),
            QueryFixture(
                id: "three", name: "Another worker", pid: 100, cpu: 90, bytes: 2_147_483_648, seconds: 180,
                locked: false, modified: nil, path: "127.0.0.1:9000"
            ),
            QueryFixture(
                id: "missing", name: "Unavailable worker", pid: 101, cpu: nil, bytes: nil, seconds: nil,
                locked: false, modified: nil, path: "/tmp/CPU > 40 report"
            )
        ]
        func query(_ search: String) -> TableQuery<QueryFixture> { TableQuery(search: search, fields: QueryFields.all) }
        func ids(_ search: String) -> [String] { query(search).filter(rows).map(\.id) }

        check(ids("").count == rows.count, "empty table queries retain every row")
        check(ids("CPU% > 40") == ["two", "three"], "CPU comparison excludes the exact boundary and unavailable measurements")
        check(ids("false").isEmpty, "free text does not match synthetic boolean descriptions")
        check(ids("40.5").isEmpty, "free text does not match unrelated raw CPU counters")
        check(ids("cpu = 40.5") == ["two"], "non-searchable measurements remain available through explicit filters")
        check(ids("Example AND CPU% > 40") == ["two"], "explicit AND keeps free text separate from the following filter field")
        check(ids("cpu>=40") == ["one", "two", "three"], "numeric filters accept inclusive operators without spaces")
        check(ids("\"CPU %\" <= 40%") == ["one"], "quoted column names and percentage suffixes work")
        check(ids("Example CPU% > 40 size <= 1GB") == ["two"], "free text and multiple comparisons combine with AND")
        check(ids("process:\"Example worker\" pid != 2") == ["two"], "text aliases, quoted phrases, and numeric inequality combine")
        check(ids("name=\"example worker 2\"") == ["one"], "text equality is case-insensitive")
        check(ids("name=\"Example worker 02\"").isEmpty, "text equality does not equate distinct numeric spellings")
        check(ids("pid == 2") == ["one"], "double equals is an equality operator")
        check(ids("name != \"Another worker\" cpu < 50") == ["one", "two"], "text inequality composes with numeric filters")
        check(ids("size >= 1 GB") == ["two", "three"], "byte filters accept separate binary units")
        check(ids("size > 1024B size < 2GiB") == ["two"], "byte thresholds compare unformatted bytes")
        check(ids("CPU time > 1.5m") == ["two", "three"], "multiword duration fields accept minute units")
        check(ids("time >= 120s locked = yes") == ["two"], "duration and predefined boolean filters combine")
        check(ids("locked=false cpu != 0") == ["one", "three"], "unavailable numbers never satisfy inequality filters")
        check(ids("modified >= 2026-01-02") == ["two"], "date filters accept ISO dates and exclude unavailable dates")
        check(ids("::1") == ["two"], "IPv6 search is not mistaken for field syntax")
        check(ids("127.0.0.1:9000") == ["three"], "numeric endpoint search is not mistaken for field syntax")
        check(ids("\"CPU > 40\"") == ["missing"], "quoted comparison characters remain literal search text")
        check(ids("path:\"/tmp/example one\"") == ["one"], "quoted paths retain spaces")

        for invalid in [
            "cpu >> 40", "cpu >", "unknown > 40", "cpu > forty", "cpu > 1GB", "size > 1XB",
            "pid > 2junk", "locked > yes", "modified > invalid", "modified = 2026-02-31",
            "name:\"unfinished", "> 40", "cpu >= <= 40", "AND pid = 2", "pid = 2 AND", "pid = 2 AND AND cpu > 1",
            "modified = 2026-02-31T00:00:00Z"
        ] {
            let result = query(invalid)
            check(result.error != nil && result.filter(rows).isEmpty, "invalid table query reports an error instead of silently applying: \(invalid)")
        }
        check(
            query("locked:yes").error?.contains("Use = or != with Yes or No") == true,
            "boolean contains errors recommend only supported boolean operators"
        )
        for (field, operation, value) in [
            (QueryFields.cpu, ">", "40 pid = 100"),
            (QueryFields.locked, "=", "yes AND pid = 100"),
            (QueryFields.modified, ">=", "2026-01-01T00:00:00Z AND pid = 100")
        ] {
            let clause = TableFilterSyntax.comparison(field: field, operation: operation, value: value)
            check(query(clause).error != nil, "a builder value cannot introduce another query clause: \(field.title)")
        }
        check(
            ids(TableFilterSyntax.comparison(field: QueryFields.bytes, operation: ">=", value: " 1 GB ")) == ["two", "three"],
            "builder quoting retains valid numeric units and trims surrounding whitespace"
        )
        check(
            ids(TableFilterSyntax.comparison(field: QueryFields.cpu, operation: ">", value: "40")) == ["two", "three"],
            "builder numeric values remain typed comparisons when quoted"
        )
        check(
            ids(TableFilterSyntax.comparison(field: QueryFields.modified, operation: ">=", value: "2026-01-02T00:00:00Z")) == ["two"],
            "builder date values accept complete ISO timestamps"
        )

        let quoted = "Example \"quoted\" path\\file AND"
        let literal = QueryFixture(
            id: "quoted", name: quoted, pid: 1, cpu: nil, bytes: nil, seconds: nil,
            locked: false, modified: nil, path: ""
        )
        check(
            query("name = \(TableFilterSyntax.quoted(quoted))").filter([literal]).count == 1,
            "filter-builder quoting preserves quotes and backslashes"
        )
        check(query("\"AND\"").filter([literal]).count == 1, "quoted AND remains literal search text")

        var sorting = TableComparator(field: QueryFields.pid)
        check(
            query("").apply(to: rows, sorting: sorting, identity: \.id).map(\.pid) == [2, 10, 100, 101],
            "integer columns sort numerically ascending"
        )
        sorting.ascending = false
        check(
            query("").apply(to: rows, sorting: sorting, identity: \.id).map(\.pid) == [101, 100, 10, 2],
            "integer columns sort numerically descending"
        )
        sorting = TableComparator(field: QueryFields.name)
        check(
            query("").apply(to: rows, sorting: sorting, identity: \.id).map(\.id) == ["three", "one", "two", "missing"],
            "text columns use natural A-Z ordering"
        )
        sorting.ascending = false
        check(
            query("").apply(to: rows, sorting: sorting, identity: \.id).map(\.id) == ["missing", "two", "one", "three"],
            "text columns support Z-A ordering"
        )
        for field in [QueryFields.cpu, QueryFields.bytes, QueryFields.modified] {
            let absent: Set<String> = field.id == "modified" ? ["three", "missing"] : ["missing"]
            for order in [SortOrder.forward, .reverse] {
                let result = query("").apply(to: rows, sorting: TableComparator(field: field, order: order), identity: \.id)
                check(Set(result.suffix(absent.count).map(\.id)) == absent, "unavailable values sort last in both directions for \(field.title)")
            }
        }
        sorting.select(QueryFields.pid)
        check(sorting.ascending, "selecting a different column starts ascending")
        sorting.select(QueryFields.pid)
        check(!sorting.ascending, "selecting the same column reverses its direction")
        sorting.select(QueryFields.pid)
        check(sorting.ascending, "column direction can be toggled back")
        check(
            TableComparator(field: QueryFields.locked).sorted(rows, identity: \.id).map(\.locked) == [false, false, false, true],
            "boolean columns sort No before Yes"
        )
        check(
            TableComparator(field: QueryFields.locked, order: .reverse).sorted(rows, identity: \.id).map(\.locked) == [true, false, false, false],
            "boolean columns support the reverse direction"
        )

        let large = [UInt64.max, UInt64.max - 1].enumerated().map { index, bytes in
            QueryFixture(
                id: String(index), name: "Large fixture", pid: Int32(index), cpu: nil, bytes: bytes, seconds: nil,
                locked: false, modified: nil, path: ""
            )
        }
        check(
            query("size > \(UInt64.max - 1)").filter(large).map(\.bytes) == [UInt64.max],
            "large byte comparisons preserve UInt64 precision"
        )
        check(
            query("").apply(to: large, sorting: TableComparator(field: QueryFields.bytes), identity: \.id).map(\.bytes)
                == [UInt64.max - 1, UInt64.max],
            "large byte sorting does not round neighboring counters together"
        )
        let reset = query("")
        check(reset.error == nil && reset.filter(rows).count == rows.count, "clearing a query removes every text and numeric filter")

        let descriptor = ActivityProcessDescriptor(
            identity: ActivityProcessIdentity(bootSession: "synthetic-boot", pid: 42, startTime: 1),
            name: "Example worker", user: "example-user"
        )
        let sample = ActivityProcessSample(
            process: descriptor, values: ActivityValues(cpu: 155, memory: 2_147_483_648, received: 1_048_576)
        )
        let activityQuery = TableQuery(search: "CPU% > 40 memory >= 1GB", fields: ActivityTableFields.all)
        check(activityQuery.error == nil && activityQuery.filter([sample]).count == 1, "dashboard fields use the same CPU and byte filters as the shared parser")
        check(
            TableQuery(search: "received/s >= 1MB/s cpu > 100%", fields: ActivityTableFields.all).filter([sample]).count == 1,
            "dashboard rate units preserve thresholds and per-core CPU above 100 percent"
        )
        check(
            TableQuery(search: "pid > 40 user:example", fields: HistoricalProcessFields.all).filter([descriptor]).count == 1,
            "historical process search accepts typed PID and owner filters"
        )
        check(
            TableQuery(search: "cpu > 40", fields: HistoricalProcessFields.all).error != nil,
            "historical descriptor search does not pretend exited processes have current CPU measurements"
        )
    }
}
