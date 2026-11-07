import SwiftUI
import SystemMetricsCore

struct SystemHealthTab: View {
    @ObservedObject var monitor: SystemHealthMonitor
    @ObservedObject var resources: ResourceMonitor
    let page: MainTab
    @Environment(\.allowsLiveOperations) private var allowsOperations
    @Environment(\.isKillSwitchWindowVisible) private var visible
    @Environment(\.isKillSwitchPageVisible) private var pageVisible

    var body: some View {
        Group {
            if pageVisible { pageContent }
        }
    }

    private var pageContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(page.title, systemImage: page.icon)
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    if let date = monitor.snapshot?.date {
                        Text("Updated \(date.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(!visible || !allowsOperations || monitor.isRefreshing)
                        .accessibilityLabel("Refresh system health")
                }
                if let error = monitor.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                }
                switch page {
                case .battery: batteryCard
                case .thermal: thermalCard
                default:
                    hardwareCard
                    runtimeCard
                    thermalCard
                }
                Text("Public macOS counters. Health refreshes every 30 seconds while this page or the dashboard is visible. No administrator access, private sensor interfaces, serial numbers, or hardware UUIDs.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(20)
        }
        .background(Theme.background)
        .systemHealthSampling(monitor)
    }

    private var hardwareCard: some View {
        healthCard("Hardware", icon: "desktopcomputer") {
            if let hardware = monitor.hardware {
                Text(hardware.cpuName)
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                healthRow("Model", hardware.model)
                healthRow("Architecture", hardware.architecture)
                healthRow("CPU cores", "\(hardware.physicalCPUCount) physical / \(hardware.logicalCPUCount) logical")
                healthRow("Active logical cores", "\(hardware.activeCPUCount)")
                healthRow("Physical memory", formatBytes(hardware.physicalMemoryBytes))
                healthRow("macOS", hardware.operatingSystem)
                healthRow("Kernel", hardware.kernelVersion)
            } else {
                Text(monitor.errorMessage == nil ? "Collecting hardware information" : "Hardware information unavailable")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var runtimeCard: some View {
        healthCard("CPU and runtime", icon: "cpu") {
            healthRow("CPU in use", resources.cpu.isAvailable
                ? String(format: "%.1f%%", resources.cpu.userPercent + resources.cpu.systemPercent) : "N/A")
            healthRow("User / system", resources.cpu.isAvailable
                ? String(format: "%.1f%% / %.1f%%", resources.cpu.userPercent, resources.cpu.systemPercent) : "N/A")
            healthRow("Processes / threads", resources.cpu.isAvailable
                ? "\(resources.cpu.processCount) / \(resources.cpu.threadCount)" : "N/A")
            healthRow("Uptime", monitor.snapshot.map { formatDuration($0.uptime) } ?? "N/A")
            healthRow("Load averages (1 / 5 / 15 min)", monitor.snapshot?.loadAverages.map {
                $0.map { String(format: "%.2f", $0) }.joined(separator: " / ")
            } ?? "N/A")
            healthRow("Power source", monitor.snapshot?.powerSource.rawValue ?? "N/A")
            healthRow("Low Power Mode", monitor.snapshot.map { $0.lowPowerMode ? "On" : "Off" } ?? "N/A")
            Text("Global CPU uses 0-100% across the whole Mac. Process CPU uses 100% per core. Load averages count runnable or waiting work; they are not CPU percentages.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            ActivityMonitorErrors(monitor: resources)
        }
    }

    private var batteryCard: some View {
        healthCard("Battery", icon: "battery.100") {
            switch monitor.snapshot?.battery {
            case .available(let battery):
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(battery.chargePercent.map { "\($0)%" } ?? "N/A")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(batteryStatus(battery))
                        .foregroundColor(.secondary)
                }
                if let charge = battery.chargePercent {
                    ProgressView(value: Double(charge), total: 100)
                        .tint(Theme.memory)
                        .accessibilityLabel("Battery charge")
                        .accessibilityValue("\(charge) percent")
                }
                healthRow("Power source", monitor.snapshot?.powerSource.rawValue ?? "N/A")
                healthRow("Condition reported by macOS", battery.condition ?? "N/A")
                healthRow("Cycle count", battery.cycleCount.map(String.init) ?? "N/A")
                healthRow("Time to empty", battery.minutesToEmpty.map { "\($0) min" } ?? "N/A")
                healthRow("Time to full charge", battery.minutesToFull.map { "\($0) min" } ?? "N/A")
                healthRow("Low Power Mode", monitor.snapshot.map { $0.lowPowerMode ? "On" : "Off" } ?? "N/A")
                Text("Time estimates and battery condition are supplied by macOS, when available. Battery details are live and are not stored.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            case .absent:
                Label("No internal battery", systemImage: "powerplug")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("This Mac is powered by \(monitor.snapshot?.powerSource.rawValue.lowercased() ?? "an unavailable source"). An attached UPS is not reported as an internal battery.")
                    .foregroundColor(.secondary)
            case .unavailable(let message):
                Label("Battery information unavailable", systemImage: "exclamationmark.triangle")
                Text(message).foregroundColor(.secondary).textSelection(.enabled)
            case nil:
                Text("Collecting battery information").foregroundColor(.secondary)
            }
        }
    }

    private var thermalCard: some View {
        let state = monitor.snapshot?.thermalState ?? .unavailable
        return healthCard("Thermal pressure", icon: "thermometer.medium") {
            HStack(spacing: 12) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 30))
                    .foregroundColor(thermalColor(state))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.rawValue)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text(state.detail).foregroundColor(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 8) {
                ForEach(SystemThermalState.allCases.filter { $0 != .unavailable }, id: \.self) { level in
                    VStack(spacing: 6) {
                        Text(level.rawValue).font(.system(size: 12, weight: .medium))
                        Text(level == state ? "Current" : " ")
                            .font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(level == state ? thermalColor(level).opacity(0.18) : Theme.raisedPanel))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(level == state ? thermalColor(level) : Theme.border))
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Thermal pressure is macOS's assessment of heat-related performance limits, not a temperature reading. Fan speeds and sensor temperatures are not fabricated.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}

struct SystemStatusStrip: View {
    @ObservedObject var monitor: SystemHealthMonitor
    let navigate: (MainTab) -> Void
    @FocusState private var focusedPage: MainTab?

    var body: some View {
        HStack(spacing: 10) {
            status(.system, value: monitor.hardware?.cpuName ?? "System details",
                   detail: monitor.hardware.map { "\($0.logicalCPUCount) logical cores / \(formatBytes($0.physicalMemoryBytes))" } ?? "CPU, hardware, and uptime")
            status(.battery, value: batteryValue, detail: monitor.snapshot?.powerSource.rawValue ?? "Power source unavailable")
            status(.thermal, value: monitor.snapshot?.thermalState.rawValue ?? "N/A", detail: "macOS thermal pressure")
        }
        .systemHealthSampling(monitor)
    }

    private func status(_ page: MainTab, value: String, detail: String) -> some View {
        Button { navigate(page) } label: {
            HStack(spacing: 10) {
                Image(systemName: page.icon).foregroundColor(page.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(value).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundColor(.secondary)
            }
            .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 38)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(
                focusedPage == page ? Theme.accent : Theme.border, lineWidth: focusedPage == page ? 2 : 1
            ))
        }
        .buttonStyle(.plain)
        .focused($focusedPage, equals: page)
        .accessibilityLabel("\(page.title): \(value). \(detail). Open \(page.title.lowercased()).")
    }

    private var batteryValue: String {
        switch monitor.snapshot?.battery {
        case .available(let reading): return reading.chargePercent.map { "Battery \($0)%" } ?? "Battery charge unavailable"
        case .absent: return "No internal battery"
        case .unavailable, nil: return "Battery unavailable"
        }
    }
}

private func healthCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14) {
        Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.accent)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
}

private func healthRow(_ label: String, _ value: String) -> some View {
    LabeledContent(label) {
        Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
    }
    .font(.system(size: 12))
    .frame(maxWidth: .infinity, alignment: .leading)
}

private func thermalColor(_ state: SystemThermalState) -> Color {
    switch state {
    case .nominal: return Theme.memory
    case .fair, .serious: return Theme.energy
    case .critical: return Theme.cpuSystem
    case .unavailable: return .secondary
    }
}

private func batteryStatus(_ reading: SystemBatteryReading) -> String {
    if reading.isFullyCharged == true { return "Fully charged" }
    if reading.isCharging == true { return "Charging" }
    if reading.isCharging == false { return "Not charging" }
    return "Charging status unavailable"
}
