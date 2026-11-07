import Foundation
import IOKit.ps
import Darwin
import SystemMetricsCore

extension SystemMetricsChecks {
    static func checkSystemHealth() {
        do {
            let arm = try MachTimebase(numerator: 125, denominator: 3)
            let intel = try MachTimebase(numerator: 1, denominator: 1)
            check(approximately(arm.seconds(ticks: 24_000_000), 1), "Apple Silicon Mach ticks convert to CPU seconds")
            check(approximately(intel.seconds(ticks: 1_000_000_000), 1), "Intel Mach ticks retain nanosecond scaling")
            check(
                SystemMetricsCalculator.processCPUPercent(
                    currentTicks: 48_000_000, previousTicks: 24_000_000, elapsedSeconds: 1, timebase: arm
                ).map { approximately($0, 100) } == true,
                "Mach CPU rates use the platform timebase before one-core normalization"
            )
            check(
                SystemMetricsCalculator.processCPUPercent(
                    currentTicks: 1, previousTicks: 2, elapsedSeconds: 1, timebase: arm
                ) == nil,
                "regressed Mach CPU counters stay unavailable"
            )
        } catch { check(false, "synthetic Mach timebase: \(error.localizedDescription)") }
        do {
            _ = try MachTimebase(numerator: 1, denominator: 0)
            check(false, "an invalid Mach timebase must not invent CPU rates")
        } catch { check(true, "an invalid Mach timebase must not invent CPU rates") }
        do {
            let translated = try SystemHealthReader.architectureForTranslation(status: 0, value: 1, size: 4, error: 0)
            let nativeIntel = try SystemHealthReader.architectureForTranslation(status: -1, value: 0, size: 4, error: ENOENT)
            check(
                translated == "Apple Silicon (Rosetta)",
                "translated Intel executable still identifies Apple Silicon hardware"
            )
            check(
                nativeIntel == "Intel",
                "an absent translation key identifies native Intel"
            )
        } catch { check(false, "synthetic architecture decoding: \(error.localizedDescription)") }
        do {
            _ = try SystemHealthReader.architectureForTranslation(status: -1, value: 0, size: 4, error: EPERM)
            check(false, "a restricted translation read must not invent Intel hardware")
        } catch { check(true, "a restricted translation read must not invent Intel hardware") }
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
        check(charging.chargingStatus(powerSource: .mains) == .charging, "charging status remains explicitly charging")
        let notCharging = SystemBatteryReading(
            currentCapacity: 80, maximumCapacity: 100, isCharging: false, isFullyCharged: false,
            minutesToEmpty: 60, minutesToFull: nil, cycleCount: nil, condition: nil
        )
        check(notCharging.chargingStatus(powerSource: .battery) == .discharging, "battery-powered non-charging status is discharging")
        check(notCharging.chargingStatus(powerSource: .mains) == .notCharging, "AC charge hold is not mislabeled as discharging")
        check(notCharging.chargingStatus(powerSource: .ups) == .notCharging, "UPS-powered non-charging status does not imply battery discharge")
        let full = SystemBatteryReading(
            currentCapacity: 100, maximumCapacity: 100, isCharging: false, isFullyCharged: true,
            minutesToEmpty: nil, minutesToFull: nil, cycleCount: nil, condition: nil
        )
        check(full.chargingStatus(powerSource: .mains) == .fullyCharged, "a reported full battery retains its charged status")
        check(full.chargingStatus(powerSource: .battery) == .discharging, "a full battery supplying power is still discharging")
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
        check(unknown.chargingStatus(powerSource: .battery) == .unavailable, "missing charging state is not invented from the power source")
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
        for type in ["AC Power", "UPS Power"] {
            do {
                let result = try SystemHealthReader.decodePowerSources(type: type, descriptions: [battery], cycleCount: nil)
                if case .available(let reading) = result.1 {
                    check(reading.minutesToEmpty == nil && reading.minutesToFull == nil
                          && reading.chargingStatus(powerSource: result.0) == .notCharging,
                          "AC/UPS charge holds must not expose stale battery-discharge estimates")
                } else { check(false, "synthetic charge-hold battery must remain available") }
            } catch { check(false, "synthetic charge-hold decoding: \(error.localizedDescription)") }
        }
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
