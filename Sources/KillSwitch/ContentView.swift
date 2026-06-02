import SwiftUI

struct ContentView: View {
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
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.15, green: 0.1, blue: 0.25),
                    Color(red: 0.2, green: 0.12, blue: 0.3)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onAppear {
            monitor.startMonitoring()
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left")
                .foregroundColor(.gray)
                .font(.system(size: 14, weight: .medium))

            TextField("Filter by name...", text: $monitor.filterText)
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
            Text("Kill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
            Text("⏎")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
            Text("|")
                .foregroundColor(.white.opacity(0.2))
            Text("Actions")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
            Text("⌘K")
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
            Image(systemName: "app.fill")
                .font(.system(size: 14))
                .foregroundColor(.blue.opacity(0.7))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("PID: \(process.pid)")
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

                Button(action: onKill) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Kill process \(process.pid)")
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

    private func formatMemory(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
}
