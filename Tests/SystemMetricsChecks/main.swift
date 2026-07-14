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
