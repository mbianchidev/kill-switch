import Darwin
import Foundation
import SystemMetricsCore

@main
struct SystemMetricsChecks {
    private static var failures: [String] = []
    private static var checkCount = 0

    static func main() {
        checkTopParsing()
        checkNetworkProcessParsing()
        checkNetworkTotalsParsing()
        checkBatteryPressureAndAssertions()
        checkByteAndDurationParsing()
        checkPSProcessParsing()
        checkCPUCalculations()
        checkDiskCapacityCalculations()
        checkSamplingPolicies()

        if failures.isEmpty {
            print("SystemMetricsChecks: \(checkCount) checks passed")
            return
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        fputs("SystemMetricsChecks: \(failures.count) of \(checkCount) checks failed\n", stderr)
        exit(EXIT_FAILURE)
    }

    private static func checkTopParsing() {
        let output = """
        Processes: 778 total, 6 running, 772 sleeping, 6900 threads
        CPU usage: 40.0% user, 20.0% sys, 40.0% idle
        PID    %CPU TIME     #TH IDLEW POWER MEM   #PORTS USER        COMMAND
        100    0.0  00:01.00 2   1     0.0   10M   20     user        Old Process
        Processes: 780 total, 4 running, 1 stuck, 775 sleeping, 6920 threads
        CPU usage: 22.39% user, 12.19% sys, 65.40% idle
        SharedLibs: 628M resident.
        PID    %CPU TIME     #TH  IDLEW POWER MEM   #PORTS USER         COMMAND
        18954  14.8 21:41.90 50   2627  14.8  641M+ 1706-  mbianchidev  Google Chrome
        439    16.3 04:15:33 21/1 558088 16.3  793M+ 4021+  _windowserver WindowServer
        """

        do {
            let snapshot = try SystemMetricsParser.parseTop(output)
            check(snapshot.cpu.processCount == 780, "top total process count")
            check(snapshot.cpu.runningCount == 4, "top running process count")
            check(snapshot.cpu.threadCount == 6920, "top thread count")
            check(approximately(snapshot.cpu.userPercent, 22.39), "top user CPU")
            check(approximately(snapshot.cpu.systemPercent, 12.19), "top system CPU")
            check(approximately(snapshot.cpu.idlePercent, 65.40), "top idle CPU")
            check(snapshot.processes.count == 2, "top final snapshot row count")

            guard let chrome = snapshot.processes.first else {
                check(false, "top first process exists")
                return
            }
            check(chrome.pid == 18954, "top PID")
            check(chrome.command == "Google Chrome", "top command with spaces")
            check(approximately(chrome.cpu, 14.8), "top process CPU")
            check(approximately(chrome.cpuTimeSeconds, 1_301.9), "top process CPU time")
            check(chrome.threads == 50, "top process threads")
            check(chrome.idleWakeUps == 2627, "top process idle wakeups")
            check(chrome.memoryBytes == 641 * 1_048_576, "top process memory")
            check(chrome.ports == 1706, "top process ports with delta suffix")
            check(chrome.user == "mbianchidev", "top process user")
        } catch {
            check(false, "top parsing threw \(error)")
        }
    }

    private static func checkNetworkProcessParsing() {
        let output = """
        ,packets_in,bytes_in,packets_out,bytes_out,
        com.apple.WebKi.35850,20,4832,10,3604,
        github.35705,22895,21909715,1179490,904214811,
        """

        let result = SystemMetricsParser.parseNetworkProcesses(output)
        check(result[35850]?.receivedPackets == 20, "nettop received packets")
        check(result[35850]?.receivedBytes == 4832, "nettop received bytes")
        check(result[35850]?.sentPackets == 10, "nettop sent packets")
        check(result[35850]?.sentBytes == 3604, "nettop sent bytes")
        check(result[35705]?.sentBytes == 904_214_811, "nettop final row")
    }

    private static func checkNetworkTotalsParsing() {
        let output = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        lo0        16384 <Link#1>                       100     0 1000  200     0 2000 0
        lo0        16384 127           127.0.0.1        100     - 1000  200     - 2000 -
        en0        1500  <Link#11>   00:00:00:00:00:00 300     0 4000  500     0 6000 0
        utun0      1500  <Link#15>                      7       0 8000  9       0 10000 0
        """

        guard let totals = SystemMetricsParser.parseNetworkTotals(output) else {
            check(false, "netstat totals exist")
            return
        }
        check(totals.receivedPackets == 407, "netstat unique received packets")
        check(totals.receivedBytes == 13_000, "netstat unique received bytes")
        check(totals.sentPackets == 709, "netstat unique sent packets")
        check(totals.sentBytes == 18_000, "netstat unique sent bytes")
    }

    private static func checkBatteryPressureAndAssertions() {
        let battery = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true
        """
        let assertions = """
        pid 100(one): [x] PreventUserIdleSystemSleep named: "work"
        pid 200(two): [x] UserIsActive named: "input"
        pid 300(three): [x] PreventUserIdleDisplaySleep named: "display"
        """

        let parsedBattery = SystemMetricsParser.parseBattery(battery)
        check(parsedBattery.source == "AC Power", "battery source")
        check(parsedBattery.chargePercent == 100, "battery charge")
        check(parsedBattery.status == "charged", "battery status")
        check(parsedBattery.timeRemaining == nil, "battery full time")
        check(
            SystemMetricsParser.parseMemoryPressureFreePercentage(
                "System-wide memory free percentage: 46%"
            ) == 46,
            "memory pressure percentage"
        )
        check(
            SystemMetricsParser.parsePreventingSleepPIDs(assertions) == Set([Int32(100), Int32(300)]),
            "sleep assertion filtering"
        )
    }

    private static func checkByteAndDurationParsing() {
        check(SystemMetricsParser.parseByteCount("641M+") == 641 * 1_048_576, "byte suffix delta")
        check(SystemMetricsParser.parseByteCount("1.5 GB") == 1_610_612_736, "byte decimal unit")
        check(
            SystemMetricsParser.parseCPUTime("21:41.90").map { approximately($0, 1_301.9) } == true,
            "short CPU duration"
        )
        check(
            SystemMetricsParser.parseCPUTime("1:02:03").map { approximately($0, 3_723) } == true,
            "hour CPU duration"
        )
        check(
            SystemMetricsParser.parseCPUTime("2-01:02:03").map { approximately($0, 176_523) } == true,
            "day CPU duration"
        )
    }

    private static func checkPSProcessParsing() {
        let output = """
             1 root             Ss     0.0  52:23.69  19664 /sbin/launchd
           181 mbianchidev      RN    12.5   0:01.29   6832 npm exec @microsoft/workiq mcp
        malformed row
        """

        let processes = SystemMetricsParser.parsePSProcesses(output)
        check(processes.count == 2, "ps process row count")
        check(processes[0].pid == 1, "ps PID")
        check(processes[0].user == "root", "ps user")
        check(!processes[0].isRunning, "ps sleeping state")
        check(processes[1].isRunning, "ps running state")
        check(approximately(processes[1].cpu, 12.5), "ps process CPU")
        check(approximately(processes[1].cpuTimeSeconds, 1.29), "ps process CPU time")
        check(processes[1].memoryBytes == 6_832 * 1_024, "ps memory bytes")
        check(processes[1].command == "npm exec @microsoft/workiq mcp", "ps command with spaces")
    }

    private static func checkCPUCalculations() {
        let previous = SystemCPUTicks(user: 100, nice: 50, system: 100, idle: 250)
        let current = SystemCPUTicks(user: 300, nice: 100, system: 200, idle: 400)
        let usage = SystemMetricsCalculator.systemCPUUsage(current: current, previous: previous)

        check(approximately(usage.userPercent, 50), "system user CPU delta")
        check(approximately(usage.systemPercent, 20), "system CPU delta")
        check(approximately(usage.idlePercent, 30), "system idle CPU delta")
        let initialUsage = SystemMetricsCalculator.systemCPUUsage(current: current, previous: nil)
        check(approximately(initialUsage.userPercent, 0), "initial system user CPU")
        check(approximately(initialUsage.systemPercent, 0), "initial system CPU")
        check(approximately(initialUsage.idlePercent, 0), "initial system idle CPU")
        check(
            SystemMetricsCalculator.processCPUPercent(
                currentNanoseconds: 5_000_000_000,
                previousNanoseconds: 2_000_000_000,
                elapsedSeconds: 2
            ).map { approximately($0, 150) } == true,
            "multi-core process CPU delta"
        )
        check(
            SystemMetricsCalculator.processCPUPercent(
                currentNanoseconds: 1,
                previousNanoseconds: 2,
                elapsedSeconds: 1
            ) == nil,
            "process CPU counter regression"
        )
        check(
            SystemMetricsCalculator.processCPUPercent(
                currentNanoseconds: 2,
                previousNanoseconds: 1,
                elapsedSeconds: 0.01
            ) == nil,
            "process CPU minimum interval"
        )
    }

    private static func checkDiskCapacityCalculations() {
        let capacity = DiskCapacity(totalBytes: 1_000, freeBytes: 250)
        check(capacity.occupiedBytes == 750, "disk occupied bytes")
        check(approximately(capacity.occupiedFraction, 0.75), "disk occupied fraction")

        let clamped = DiskCapacity(totalBytes: 500, freeBytes: 750)
        check(clamped.freeBytes == 500, "disk free bytes clamp to total")
        check(clamped.occupiedBytes == 0, "disk occupied bytes avoid underflow")
        check(clamped.occupiedFraction == 0, "disk empty capacity fraction")
    }

    private static func checkSamplingPolicies() {
        let cpu = ResourceSamplingPolicy.forMetric(.cpu)
        check(!cpu.usesTop, "CPU avoids top")
        check(!cpu.collectsNetwork, "CPU avoids network subprocesses")
        check(!cpu.collectsMemoryPressure, "CPU avoids memory-pressure subprocess")
        check(cpu.intervalSeconds == 6, "CPU refresh interval")

        let memory = ResourceSamplingPolicy.forMetric(.memory)
        check(memory.collectsMemoryPressure, "memory collects pressure")
        check(!memory.usesTop, "memory avoids top")

        let energy = ResourceSamplingPolicy.forMetric(.energy)
        check(energy.usesTop, "energy uses top power sampling")
        check(energy.collectsEnergyDetails, "energy collects battery and assertions")
        check(energy.intervalSeconds == 15, "energy reduced refresh cadence")

        let network = ResourceSamplingPolicy.forMetric(.network)
        check(network.collectsNetwork, "network enables network subprocesses")
        check(!network.usesTop, "network avoids top")

        let disk = ResourceSamplingPolicy.forMetric(.disk)
        check(!disk.usesTop && !disk.collectsNetwork, "disk uses native collection")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checkCount += 1
        if !condition() {
            failures.append(message)
        }
    }

    private static func approximately(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.001) -> Bool {
        abs(lhs - rhs) < tolerance
    }
}
