import Darwin
import SwiftUI
import SystemMetricsCore
import TableQueryCore

/// Resolves PTR names for destination addresses off the main thread, a few at a time,
/// and caches names and definitive "no name" answers for the app's lifetime. Failed lookups
/// are retried once a minute while their destination is shown.
@MainActor
final class ReverseDNSCache: ObservableObject {
    static let shared = ReverseDNSCache()
    private static let maximumEntries = 4_096
    private static let retryInterval: TimeInterval = 60

    enum Entry: Equatable {
        case resolving
        case resolved(String?)
        case failed(Date)
    }

    @Published private(set) var entries: [String: Entry] = [:]
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "killswitch.reverse-dns"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        return queue
    }()

    private init() {}

    func resolve(_ addresses: [String]) {
        let now = Date()
        let pending = addresses.filter { address in
            switch entries[address] {
            case nil: return true
            case .failed(let at): return now.timeIntervalSince(at) >= Self.retryInterval
            case .resolving, .resolved: return false
            }
        }
        guard !pending.isEmpty else { return }
        if entries.count + pending.count > Self.maximumEntries {
            // Keep the requested addresses so visible rows keep their names and in-flight lookups.
            let requested = Set(addresses)
            entries = entries.filter { requested.contains($0.key) }
        }
        for address in pending {
            entries[address] = .resolving
            queue.addOperation { [weak self] in
                let result = ReverseDNS.lookup(address)
                DispatchQueue.main.async {
                    // A lookup for an address evicted meanwhile must not recreate its entry.
                    guard let self, self.entries[address] == .resolving else { return }
                    switch result {
                    case .name(let name): self.entries[address] = .resolved(name)
                    case .noName: self.entries[address] = .resolved(nil)
                    case .failed: self.entries[address] = .failed(Date())
                    }
                }
            }
        }
    }

    func name(for address: String) -> String? {
        if case .resolved(let name) = entries[address] { return name }
        return nil
    }
}

struct DestinationRow: Identifiable {
    let destination: NetworkDestination
    let hostname: String?
    var id: String { destination.id }
    var processNames: String { destination.processes.map { "\($0.name) (\(pidString($0.pid)))" }.joined(separator: ", ") }
}

private enum DestinationTableFields {
    static let address = TableField<DestinationRow>.text("address", title: "Address", aliases: ["ip"]) { $0.destination.address }
    static let host = TableField<DestinationRow>.text("host", title: "Hostname", aliases: ["name", "dns"]) { $0.hostname }
    static let scope = TableField<DestinationRow>.text(
        "scope", title: "Scope", values: NetworkAddressScope.allCases.map(\.rawValue), searchable: false
    ) { $0.destination.scope.rawValue }
    static let connections = TableField<DestinationRow>.number("connections", title: "Connections", aliases: ["count"]) {
        (row: DestinationRow) -> Decimal? in Decimal(row.destination.connectionCount)
    }
    static let processes = TableField<DestinationRow>.text("process", title: "Processes", aliases: ["app"]) { $0.processNames }
    static let ports = TableField<DestinationRow>.text("ports", title: "Remote ports", aliases: ["port"]) {
        $0.destination.ports.map(String.init).joined(separator: ", ")
    }
    static let columns = [address, host, scope, connections, processes]
    static let all = columns + [ports]
}

struct DestinationsTab: View {
    let resourceMonitor: ResourceMonitor
    @ObservedObject private var resolver = ReverseDNSCache.shared
    @StateObject private var monitor = ProcessInspectionMonitor()
    @State private var showAllUsers: Bool
    @State private var includeLoopback = false
    @State private var search = ""
    @State private var sorting = TableComparator(field: DestinationTableFields.connections, order: .reverse)
    @State private var selection: DestinationRow.ID?
    @State private var interfaces: [NetworkInterfaceAddress] = []
    @State private var interfaceError: String?
    @Environment(\.isKillSwitchPageVisible) private var pageVisible
    @Environment(\.allowsLiveOperations) private var allowsOperations

    init(resourceMonitor: ResourceMonitor) {
        self.resourceMonitor = resourceMonitor
        _showAllUsers = State(initialValue: resourceMonitor.showAllUsers)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(page: .destinations, subtitle: "Remote addresses this Mac is connected to, and this Mac's own IP addresses.") {
                ProcessScopePicker(monitor: resourceMonitor)
            }
            Divider()
            if pageVisible { content }
        }
        .background(Theme.background)
        .onReceive(resourceMonitor.$showAllUsers.removeDuplicates()) { showAllUsers = $0 }
    }

    private var content: some View {
        let scoped = showAllUsers ? monitor.connections : monitor.connections.filter { $0.userID == getuid() }
        let destinations = NetworkDestinationGrouping.group(scoped, includeLoopback: includeLoopback)
        let all = destinations.map { DestinationRow(destination: $0, hostname: resolver.name(for: $0.address)) }
        let rows = TableQuery(search: search, fields: DestinationTableFields.all).apply(to: all, sorting: sorting, identity: \.id)
        return VStack(alignment: .leading, spacing: 10) {
            TableSearchControls(search: $search, fields: DestinationTableFields.all, prompt: "Search addresses, hostnames, or processes",
                                resetAdditional: { includeLoopback = false })
            HStack {
                Toggle("Include loopback", isOn: $includeLoopback)
                    .toggleStyle(.checkbox)
                    .help("Show connections to 127.0.0.1 and ::1")
                TableSortControls(fields: DestinationTableFields.all, sorting: $sorting)
                Spacer()
                InspectionRefreshButton(monitor: monitor)
            }
            InspectionStatus(monitor: monitor, count: rows.count, noun: "destinations")
            Table(rows, selection: $selection, sortOrder: tableSortOrder($sorting)) {
                TableColumn("Address", sortUsing: TableComparator(field: DestinationTableFields.address)) {
                    Text($0.destination.address).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
                .width(min: 120, ideal: 170)
                TableColumn("Hostname", sortUsing: TableComparator(field: DestinationTableFields.host)) { row in
                    Text(hostnameText(row)).foregroundColor(row.hostname == nil ? .secondary : .primary).lineLimit(1)
                }
                .width(min: 120, ideal: 220)
                TableColumn("Scope", sortUsing: TableComparator(field: DestinationTableFields.scope)) {
                    Text($0.destination.scope.rawValue)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Ports") {
                    Text($0.destination.ports.map(String.init).joined(separator: ", ")).font(.system(size: 11, design: .monospaced))
                }
                .width(min: 60, ideal: 90)
                TableColumn("Connections", sortUsing: TableComparator(field: DestinationTableFields.connections)) {
                    Text("\($0.destination.connectionCount)")
                }
                .width(80)
                TableColumn("Processes", sortUsing: TableComparator(field: DestinationTableFields.processes)) { row in
                    Text(row.processNames).lineLimit(1).copyOnClick(row.processNames, label: "process names and PIDs")
                }
                .width(min: 160, ideal: 260)
            }
            .frame(minHeight: 220)
            .overlay {
                if rows.isEmpty && !monitor.isRefreshing {
                    Text(monitor.lastUpdated == nil ? "Collecting connections" : "No matching destinations")
                        .foregroundColor(.secondary)
                }
            }
            interfaceSection
            Text("Groups the active TCP and UDP connections visible to this account by remote address, refreshed every 10 seconds. Hostnames come from reverse DNS lookups through this Mac's resolver and may be missing or differ from the name an app connected to.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .inspectionSampling(monitor, mode: .connections)
        .onAppear { readInterfaces() }
        .onChange(of: monitor.lastUpdated) { _ in
            readInterfaces()
            // Retries failed lookups on each refresh; cached names are not looked up again.
            if allowsOperations { resolver.resolve(destinations.map(\.address)) }
        }
        .onChange(of: destinations.map(\.address)) { addresses in
            if allowsOperations { resolver.resolve(addresses) }
        }
        .onAppear { if allowsOperations { resolver.resolve(destinations.map(\.address)) } }
    }

    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This Mac's IP addresses")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
            if let interfaceError {
                NoticeBanner(message: interfaceError)
            }
            Table(interfaces) {
                TableColumn("Interface") { Text($0.interface).font(.system(size: 11, design: .monospaced)) }
                    .width(min: 60, ideal: 80)
                TableColumn("Family") { Text($0.family) }
                    .width(50)
                TableColumn("Address") { address in
                    Text(address.prefixLength.map { "\(address.address)/\($0)" } ?? address.address)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                .width(min: 160, ideal: 280)
                TableColumn("Scope") { Text($0.scope.rawValue) }
                    .width(min: 80, ideal: 110)
                TableColumn("Status") { Text($0.isUp ? "Up" : "Down").foregroundColor($0.isUp ? .green : .secondary) }
                    .width(60)
            }
            .frame(minHeight: 140, idealHeight: 180)
        }
    }

    private func hostnameText(_ row: DestinationRow) -> String {
        switch resolver.entries[row.destination.address] {
        case .resolving, nil: return "Resolving…"
        case .resolved(let name): return name ?? "No reverse DNS name"
        case .failed: return "Lookup failed; retrying"
        }
    }

    private func readInterfaces() {
        guard allowsOperations else { return }
        do {
            interfaces = try NetworkInterfaceReader.addresses()
            interfaceError = nil
        } catch {
            interfaceError = error.localizedDescription
        }
    }
}
