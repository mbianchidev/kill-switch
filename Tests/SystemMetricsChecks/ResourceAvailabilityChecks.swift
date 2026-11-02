import Foundation
import SystemMetricsCore
import TableQueryCore

extension SystemMetricsChecks {
    static func checkResourceAvailability() {
        checkAvailabilityParsing()
        let known = ActivityProcessIdentity(bootSession: "synthetic-boot", pid: 42, startTime: 1)
        let reused = ActivityProcessIdentity(bootSession: "synthetic-boot", pid: 42, startTime: 2)
        let newProcess = ActivityProcessIdentity(bootSession: "synthetic-boot", pid: 43, startTime: 1)
        let identities = [known.pid: known]
        let descriptor = ActivityProcessDescriptor(identity: known, name: "Alpha", user: "example-user")
        let unmeasuredCPU = ActivityProcessSample(process: descriptor, values: ActivityValues())
        let measuredZeroCPU = ActivityProcessSample(
            process: ActivityProcessDescriptor(identity: newProcess, name: "Beta", user: "example-user"),
            values: ActivityValues(cpu: 0)
        )
        for expression in ["cpu = 0", "cpu < 1"] {
            check(
                TableQuery(search: expression, fields: ActivityTableFields.all)
                    .filter([unmeasuredCPU, measuredZeroCPU]) == [measuredZeroCPU],
                "CPU filters distinguish unmeasured rates from a genuine zero: \(expression)"
            )
        }
        var cache = ProcessEnergyCache()
        check(cache.power(for: known) == nil, "power is unavailable before the first successful energy read")
        check(cache.preventsSleep(for: known) == nil, "sleep assertions are unknown before the first successful read")

        cache.updatePower([known.pid: 0], identities: identities)
        cache.updateSleepAssertions([], identities: identities)
        check(cache.power(for: known) == 0, "a measured zero power value stays zero")
        check(cache.preventsSleep(for: known) == false, "a readable empty assertion inventory establishes No")
        check(cache.power(for: reused) == nil && cache.preventsSleep(for: reused) == nil, "PID reuse never inherits another lifetime's energy or sleep state")
        check(cache.power(for: newProcess) == nil && cache.preventsSleep(for: newProcess) == nil, "processes created after an energy read remain unknown")
        check(cache.power(for: nil) == nil && cache.preventsSleep(for: nil) == nil, "unverified process identities remain unknown")

        let measured = cache
        let power = TableField<ActivityProcessIdentity>.number("energy", title: "Energy") { measured.power(for: $0) }
        let sleep = TableField<ActivityProcessIdentity>.boolean("preventsSleep", title: "Preventing Sleep") { measured.preventsSleep(for: $0) }
        let fields = [power, sleep]
        let rows = [newProcess, known, reused]
        check(TableQuery(search: "energy = 0", fields: fields).filter(rows) == [known], "zero-energy filters exclude unmeasured process lifetimes")
        check(TableQuery(search: "energy < 1", fields: fields).filter(rows) == [known], "low-energy filters exclude unavailable power")
        check(TableQuery(search: "preventsSleep = no", fields: fields).filter(rows) == [known], "No assertion filters require a successful read for that lifetime")
        for order in [SortOrder.forward, .reverse] {
            check(
                TableComparator(field: power, order: order).sorted(rows, identity: \.key).first == known,
                "measured zero sorts before unavailable power in both directions"
            )
        }

        cache.updatePower(nil, identities: identities)
        check(cache.power(for: known) == nil && cache.preventsSleep(for: known) == false, "a failed power read does not invent zero or discard independently readable assertions")
        cache.updateSleepAssertions(nil, identities: identities)
        check(cache.preventsSleep(for: known) == nil, "a failed assertion read cannot retain a definite No")
        cache.updatePower([known.pid: 2], identities: identities)
        cache.updateSleepAssertions([known.pid], identities: identities)
        check(cache.power(for: known) == 2 && cache.preventsSleep(for: known) == true, "successful retries restore measured power and assertion state")
        cache.updatePower([known.pid: .nan], identities: identities)
        check(cache.power(for: known) == nil, "non-finite power stays unavailable")

        check(ProcessEnergyCache.totalPower([nil, nil]) == nil, "an entirely unavailable energy summary is not zero")
        check(ProcessEnergyCache.totalPower([nil, 0]) == 0, "an available measured zero can be summarized")
        check(ProcessEnergyCache.totalPower([nil, 0, 2]) == 2, "reported energy totals include only available measurements")
    }

    private static func checkAvailabilityParsing() {
        let output = """
        Processes: 2 total, 0 running, 2 sleeping, 2 threads
        CPU usage: 0.0% user, 0.0% sys, 100.0% idle
        PID %CPU TIME #TH IDLEW POWER MEM #PORTS USER COMMAND
        42 0.0 00:01.00 1 0 N/A 1M 1 example-user Alpha
        43 0.0 00:01.00 1 0 0.0 1M 1 example-user Beta
        """
        do {
            let snapshot = try SystemMetricsParser.parseTop(output)
            check(snapshot.processes.first?.power == nil, "unreadable top power is unavailable rather than a measured zero")
            check(snapshot.processes.last?.power == 0, "a readable top power zero remains a measurement")
        } catch { check(false, "synthetic power parsing: \(error.localizedDescription)") }
        let unavailable: Set<Int32>? = SystemMetricsParser.parsePreventingSleepPIDs("permission denied")
        check(unavailable == nil, "unreadable assertion output is not an empty successful inventory")
        let empty = SystemMetricsParser.parsePreventingSleepPIDs(
            "Assertion status system-wide:\nListed by owning process:\n-none-\n"
        )
        check(empty == Set<Int32>(), "a recognized empty assertion inventory is available")
        check(
            SystemMetricsParser.parsePreventingSleepPIDs(
                "Assertion status system-wide:\nListed by owning process:\npid invalid: unreadable\n"
            ) == nil,
            "malformed assertion rows do not become a definite No"
        )
    }
}
