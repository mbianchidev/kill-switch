import AppKit
import SoftwareInventoryCore
import SwiftUI
import TableQueryCore

struct ApplicationRow: Identifiable {
    let app: InstalledApplication
    let trust: ApplicationTrust?
    let cask: HomebrewPackage?

    var id: String { app.id }
    var trustTitle: String { trust?.title ?? "Checking" }
}

private enum ApplicationTableFields {
    static let name = TableField<ApplicationRow>.text("name", title: "Application", aliases: ["app"]) { $0.app.name }
    static let bundle = TableField<ApplicationRow>.text("bundle", title: "Bundle identifier", aliases: ["id"]) { $0.app.bundleIdentifier }
    static let version = TableField<ApplicationRow>.text("version", title: "Version", searchable: false) { $0.app.version }
    static let path = TableField<ApplicationRow>.text("path", title: "Path") { $0.app.path }
    static let source = TableField<ApplicationRow>.text(
        "signature", title: "Signature", aliases: ["trust", "source"],
        values: ["Notarized", "App Store", "Apple", "Local", "Unverified", "Checking"], searchable: false
    ) { $0.trustTitle }
    static let local = TableField<ApplicationRow>.boolean("local", title: "Local (not notarized)") { $0.trust.map(\.isLocal) }
    static let homebrew = TableField<ApplicationRow>.boolean("homebrew", title: "Installed by Homebrew", aliases: ["brew"]) { $0.cask != nil }
    static let cask = TableField<ApplicationRow>.text("cask", title: "Homebrew cask") { $0.cask?.fullName }
    static let modified = TableField<ApplicationRow>.date("modified", title: "Modified") { $0.app.modificationDate }
    static let columns = [name, version, source, cask, modified]
    static let all = columns + [bundle, path, local, homebrew]
}

private enum ApplicationScope: String, CaseIterable, Identifiable {
    case all = "All"
    case homebrew = "Homebrew"
    case other = "Not Homebrew"
    case local = "Local"
    var id: Self { self }

    func includes(_ row: ApplicationRow) -> Bool {
        switch self {
        case .all: return true
        case .homebrew: return row.cask != nil
        case .other: return row.cask == nil
        case .local: return row.trust?.isLocal == true
        }
    }
}

struct ApplicationsTab: View {
    @ObservedObject var monitor: ApplicationsMonitor
    @ObservedObject var homebrew: HomebrewMonitor
    @Environment(\.isKillSwitchPageVisible) private var pageVisible
    @Environment(\.allowsLiveOperations) private var allowsOperations
    @State private var scope: ApplicationScope = .all
    @State private var search = ""
    @State private var sorting = TableComparator(field: ApplicationTableFields.name)
    @State private var selection: ApplicationRow.ID?
    @State private var revealError: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(page: .applications, subtitle: subtitle) {
                if monitor.isScanning || monitor.pendingAssessments > 0 {
                    ProgressView().controlSize(.small)
                }
                Button { monitor.rescan(); homebrew.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(monitor.isScanning || !allowsOperations)
                    .help("Scan applications again")
                    .accessibilityLabel("Rescan applications")
            }
            Divider()
            if pageVisible { content }
        }
        .background(Theme.background)
        .onAppear { if pageVisible { load() } }
        .onChange(of: pageVisible) { visible in
            if visible { load() }
        }
    }

    private func load() {
        guard allowsOperations else { return }
        monitor.loadIfNeeded()
        homebrew.loadIfNeeded()
    }

    private var subtitle: String {
        let local = monitor.applications.filter { monitor.trust[$0.path]?.isLocal == true }.count
        var text = "\(monitor.applications.count) app(s) in /Applications and ~/Applications · \(local) local"
        if monitor.pendingAssessments > 0 { text += " · checking \(monitor.pendingAssessments) signature(s)" }
        return text
    }

    private var content: some View {
        let casks = HomebrewInventoryParser.casksByApplicationPath(homebrew.packages)
        let all = monitor.applications.map {
            ApplicationRow(app: $0, trust: monitor.trust[$0.path], cask: casks[$0.path])
        }
        let rows = TableQuery(search: search, fields: ApplicationTableFields.all)
            .apply(to: all.filter(scope.includes), sorting: sorting, identity: \.id)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(monitor.failures, id: \.self) { NoticeBanner(message: $0) }
            if let revealError {
                NoticeBanner(message: revealError) { self.revealError = nil }
            }
            if let error = homebrew.errorMessage, homebrew.installation != nil {
                NoticeBanner(message: "Homebrew markers may be incomplete. \(error)")
            }
            TableSearchControls(search: $search, fields: ApplicationTableFields.all, prompt: "Search apps, or local = yes",
                                resetAdditional: { scope = .all })
            HStack {
                Picker("Show", selection: $scope) {
                    ForEach(ApplicationScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 340)
                TableSortControls(fields: ApplicationTableFields.all, sorting: $sorting)
                Spacer()
                Text("\(rows.count) of \(all.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Table(rows, selection: $selection, sortOrder: tableSortOrder($sorting)) {
                TableColumn("Application", sortUsing: TableComparator(field: ApplicationTableFields.name)) { row in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.path))
                            .resizable()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.app.name).font(.system(size: 12, weight: .medium))
                            Text(row.app.bundleIdentifier ?? row.app.path)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .help(row.app.path)
                }
                .width(min: 200, ideal: 280)
                TableColumn("Version", sortUsing: TableComparator(field: ApplicationTableFields.version)) {
                    Text($0.app.version ?? "—").font(.system(size: 11, design: .monospaced))
                }
                .width(min: 60, ideal: 90)
                TableColumn("Signature", sortUsing: TableComparator(field: ApplicationTableFields.source)) { row in
                    trustBadge(row.trust).help(row.trust?.detail ?? "Gatekeeper assessment is in progress.")
                }
                .width(min: 90, ideal: 110)
                TableColumn("Homebrew", sortUsing: TableComparator(field: ApplicationTableFields.cask)) { row in
                    if let cask = row.cask {
                        StatusBadge(title: cask.name, color: Theme.energy, systemImage: "mug.fill")
                            .help("Installed by the Homebrew cask \(cask.fullName)")
                    } else {
                        Text("—").foregroundColor(.secondary)
                    }
                }
                .width(min: 90, ideal: 140)
                TableColumn("Modified", sortUsing: TableComparator(field: ApplicationTableFields.modified)) {
                    Text($0.app.modificationDate?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                        .font(.system(size: 11))
                }
                .width(min: 80, ideal: 100)
                TableColumn("") { row in
                    Button { reveal(row.app.path) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                        .accessibilityLabel("Reveal \(row.app.name) in Finder")
                }
                .width(30)
            }
            .overlay {
                if rows.isEmpty && !monitor.isScanning {
                    Text(all.isEmpty ? "No applications found." : "No matching applications. Change or reset the filters.")
                        .foregroundColor(.secondary)
                }
            }
            Text("Local apps are not notarized: Gatekeeper rejected them or found no notarized Developer ID, Mac App Store, or Apple signature. That includes ad-hoc builds such as KillSwitch itself. Homebrew marks apps installed by a cask. Apps inside /System/Applications are not listed.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(12)
    }

    private func trustBadge(_ trust: ApplicationTrust?) -> some View {
        switch trust {
        case .notarized: return StatusBadge(title: "Notarized", color: .green, systemImage: "checkmark.seal.fill")
        case .appStore: return StatusBadge(title: "App Store", color: Theme.cpuUser, systemImage: "bag.fill")
        case .apple: return StatusBadge(title: "Apple", color: .white.opacity(0.7), systemImage: "applelogo")
        case .local: return StatusBadge(title: "Local", color: .orange, systemImage: "hammer.fill")
        case .unverified: return StatusBadge(title: "Unverified", color: .red, systemImage: "questionmark.circle")
        case nil: return StatusBadge(title: "Checking", color: .secondary, systemImage: "hourglass")
        }
    }

    private func reveal(_ path: String) {
        revealError = revealInFinder(path) ? nil : "The application no longer exists: \(path)"
    }
}
