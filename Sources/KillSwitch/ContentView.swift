import SwiftUI

struct ContentView: View {
    @StateObject private var topConsumers = TopConsumersMonitor()
    @StateObject private var energy = EnergyMonitor()
    @StateObject private var watchdog = CPUWatchdog()

    var body: some View {
        TabView {
            ProcessesTab()
                .tabItem { Label("Processes", systemImage: "list.bullet") }
            DevCleanupTab()
                .tabItem { Label("Dev cleanup", systemImage: "trash") }
            TopConsumersTab(monitor: topConsumers)
                .tabItem { Label("Top consumers", systemImage: "chart.bar") }
            EnergyTab(monitor: energy)
                .tabItem { Label("Energy", systemImage: "bolt.fill") }
            CPUWatchdogTab(monitor: watchdog)
                .tabItem { Label("Watchdog", systemImage: "exclamationmark.triangle") }
        }
        .padding(.top, 4)
        .background(Theme.background)
        .onAppear {
            topConsumers.start()
            energy.start()
            watchdog.start()
        }
    }
}

struct ProcessesTab: View {
    @StateObject private var monitor = ProcessMonitor()
    @State private var selectedPid: Int32?

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            processListView
            Divider()
            footerView
        }
        .background(Theme.background)
        .onAppear { monitor.startMonitoring() }
        .onDisappear { monitor.stopMonitoring() }
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
                .font(.system(size: 14, weight: .medium))

            TextField("Filter by name or PID...", text: $monitor.filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundColor(.white)
                .padding(.vertical, 8)

            Picker("", selection: $monitor.sortBy) {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    private var processListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Processes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Text("\(monitor.runningCount) running")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(monitor.filteredProcesses) { process in
                        ProcessRow(
                            process: process,
                            isSelected: selectedPid == process.pid,
                            onSelect: { selectedPid = process.pid },
                            onKill: { monitor.killProcess(pid: process.pid) }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private var footerView: some View {
        HStack {
            Image(systemName: "terminal")
                .foregroundColor(.yellow)
                .font(.system(size: 14))
            Text("Kill Process")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
            Text("Click the ✕ to terminate (SIGTERM, then SIGKILL)")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.3))
    }
}

struct ProcessRow: View {
    let process: ProcessEntry
    let isSelected: Bool
    let onSelect: () -> Void
    let onKill: () -> Void

    var body: some View {
        HStack {
            processIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("PID: \(String(process.pid))")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer()

            HStack(spacing: 16) {
                Label(String(format: "%.1f%%", process.cpu), systemImage: "cpu")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))

                Label(formatMemory(process.memory), systemImage: "memorychip")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))

                KillButton(pid: process.pid, action: onKill)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    @ViewBuilder
    private var processIcon: some View {
        if let icon = process.icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 14))
                .foregroundColor(.blue.opacity(0.7))
        }
    }
}
