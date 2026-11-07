import Foundation
import IOKit.ps
import SystemMetricsCore

extension SystemMetricsChecks {
    static func checkSystemHealth() {
        check(
            SystemBatteryReading.chargePercentage(current: 3_200, maximum: 4_000) == 80,
            "battery charge uses current capacity relative to the reported maximum"
        )
        check(
            SystemBatteryReading.chargePercentage(current: nil, maximum: 100) == nil
                && SystemBatteryReading.chargePercentage(current: 50, maximum: nil) == nil,
            "missing battery capacity does not become zero charge"
        )
        for capacities in [(-1, 100), (101, 100), (50, 0), (50, -1)] {
            check(
                SystemBatteryReading.chargePercentage(current: capacities.0, maximum: capacities.1) == nil,
                "invalid battery capacity is unavailable: \(capacities)"
            )
        }
        check(SystemBatteryReading.chargePercentage(current: 0, maximum: 100) == 0, "measured empty charge remains zero")
        check(
            SystemBatteryReading.chargePercentage(current: Int.max, maximum: Int.max) == 100,
            "large capacity counters do not overflow"
        )
        let charging = SystemBatteryReading(
            currentCapacity: 80, maximumCapacity: 100, isCharging: true, isFullyCharged: false,
            minutesToEmpty: 200, minutesToFull: 30, cycleCount: 0, condition: " Good "
        )
        check(charging.minutesToEmpty == nil && charging.minutesToFull == 30, "charging exposes only the applicable time estimate")
        check(charging.cycleCount == 0 && charging.condition == "Good", "zero battery cycles are measured, not missing")
        let unknown = SystemBatteryReading(
            currentCapacity: nil, maximumCapacity: nil, isCharging: nil, isFullyCharged: nil,
            minutesToEmpty: -1, minutesToFull: 0, cycleCount: -1, condition: " "
        )
        check(
            unknown.chargePercent == nil && unknown.isCharging == nil && unknown.isFullyCharged == nil
                && unknown.minutesToEmpty == nil && unknown.minutesToFull == nil
                && unknown.cycleCount == nil && unknown.condition == nil,
            "unknown battery status and sentinel counters stay explicitly unavailable"
        )
        check(SystemThermalState(.nominal) == .nominal, "nominal native thermal state")
        check(SystemThermalState(.fair) == .fair, "fair native thermal state")
        check(SystemThermalState(.serious) == .serious, "serious native thermal state")
        check(SystemThermalState(.critical) == .critical, "critical native thermal state")
        do {
            let desktop = try SystemHealthReader.decodePowerSources(type: "AC Power", descriptions: [], cycleCount: nil)
            check(desktop.0 == .mains && desktop.1 == .absent, "a valid desktop power inventory has no internal battery")
        } catch {
            check(false, "synthetic desktop power inventory: \(error.localizedDescription)")
        }
        let battery: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 64, kIOPSMaxCapacityKey: 100, kIOPSIsChargingKey: false,
            kIOPSIsChargedKey: false, kIOPSTimeToEmptyKey: 180, kIOPSTimeToFullChargeKey: -1,
            kIOPSBatteryHealthKey: "Good"
        ]
        do {
            let result = try SystemHealthReader.decodePowerSources(
                type: "Battery Power", descriptions: [battery], cycleCount: 42
            )
            check(result.0 == .battery, "native battery power-source decoding")
            if case .available(let reading) = result.1 {
                check(
                    reading.chargePercent == 64 && reading.minutesToEmpty == 180
                        && reading.minutesToFull == nil && reading.cycleCount == 42,
                    "synthetic native power fields retain charge, estimates, and cycles"
                )
            } else { check(false, "a verified internal battery is available") }
        } catch { check(false, "synthetic battery decoding: \(error.localizedDescription)") }
        for descriptions in [[[:]], [[kIOPSTypeKey: kIOPSInternalBatteryType]]] {
            do {
                _ = try SystemHealthReader.decodePowerSources(type: "AC Power", descriptions: descriptions, cycleCount: nil)
                check(false, "unverifiable battery presence must fail explicitly")
            } catch { check(true, "unverifiable battery presence must fail explicitly") }
        }
        do {
            _ = try SystemHealthReader.decodePowerSources(type: nil, descriptions: [], cycleCount: nil)
            check(false, "missing power source is not a success-shaped desktop result")
        } catch { check(true, "missing power source is not a success-shaped desktop result") }
    }
}
