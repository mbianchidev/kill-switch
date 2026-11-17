import SoftwareInventoryCore
import SwiftUI
import TableQueryCore

private enum HomebrewTableFields {
    static let name = TableField<HomebrewPackage>.text("name", title: "Package", aliases: ["token", "formula", "cask"]) { $0.displayName }
    static let fullName = TableField<HomebrewPackage>.text("fullName", title: "Homebrew name") { $0.fullName }
    static let summary = TableField<HomebrewPackage>.text("description", title: "Description") { $0.summary }
    static let kind = TableField<HomebrewPackage>.text("type", title: "Type", aliases: ["kind"], values: ["Formula", "Cask"], searchable: false) {
        $0.kind.title
    }
    static let installed = TableField<HomebrewPackage>.text("installed", title: "Installed", searchable: false) { $0.installedVersion }
    static let latest = TableField<HomebrewPackage>.text("latest", title: "Latest", searchable: false) { $0.latestVersion }
    static let outdated = TableField<HomebrewPackage>.boolean("outdated", title: "Outdated") { $0.isOutdated }
    static let selfUpdating = TableField<HomebrewPackage>.boolean("selfUpdating", title: "Updates itself", aliases: ["autoUpdates"]) {
        $0.autoUpdates
    }
    static let pinned = TableField<HomebrewPackage>.boolean("pinned", title: "Pinned") { $0.isPinned }
    static let requested = TableField<HomebrewPackage>.boolean("requested", title: "Installed on request") { $0.installedOnRequest }
    static let columns = [name, kind, installed, latest]
    static let all = columns + [fullName, summary, outdated, selfUpdating, pinned, requested]
}

private enum HomebrewScope: String, CaseIterable, Identifiable {
    case all = "All"
    case outdated = "Outdated"
    case formulae = "Formulae"
    case casks = "Casks"
    var id: Self { self }

    func includes(_ package: HomebrewPackage) -> Bool {
        switch self {
        case .all: return true
        case .outdated: return package.isOutdated
        case .formulae: return package.kind == .formula
        case .casks: return package.kind == .cask
        }
    }
}

struct HomebrewTab: View {
    @ObservedObject var monitor: HomebrewMonitor
    @Environment(\.isKillSwitchPageVisible) private var pageVisible
    @Environment(\.allowsLiveOperations) private var allowsOperations
    @State private var scope: HomebrewScope = .all
    @State private var search = ""
    @State private var sorting = TableComparator(field: HomebrewTableFields.name)
    @State private var selection: HomebrewPackage.ID?
    @State private var pendingUninstall: HomebrewPackage?
    @State private var confirmUpgradeAll = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(page: .homebrew, subtitle: subtitle) { headerActions }
            Divider()
            if pageVisible { content }
        }
        .background(Theme.background)
        .onAppear { if pageVisible && allowsOperations { monitor.loadIfNeeded() } }
        .onChange(of: pageVisible) { visible in
            if visible && allowsOperations { monitor.loadIfNeeded() }
        }
        .alert("Upgrade \(monitor.upgradable.count) Homebrew package(s)?", isPresented: $confirmUpgradeAll) {
            Button("Cancel", role: .cancel) {}
            Button("Upgrade") { monitor.upgradeAll() }
        } message: {
            Text(upgradeAllMessage)
        }
        .alert(
            "Uninstall \(pendingUninstall?.displayName ?? "package")?",
            isPresented: Binding(get: { pendingUninstall != nil }, set: { if !$0 { pendingUninstall = nil } }),
            presenting: pendingUninstall
        ) { package in
            Button("Cancel", role: .cancel) { pendingUninstall = nil }
            Button("Uninstall", role: .destructive) {
                pendingUninstall = nil
                monitor.uninstall(package)
            }
        } message: { package in
            Text("Runs brew uninstall --\(package.kind.rawValue) \(package.fullName). Homebrew refuses to remove a formula that other packages need. \(package.kind == .cask ? "The cask's app is removed; its settings are kept." : "")")
        }
    }

    private var subtitle: String {
        switch monitor.availability {
        case .installed(let installation):
            let count = monitor.packages.count
            return "\(count) package(s), \(monitor.outdated.count) outdated · \(installation.executable)"
        case .notInstalled:
            return "Homebrew was not found."
        case .unknown:
            return "Upgrade or remove Homebrew formulae and casks."
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        if monitor.installation != nil {
            if monitor.isBusy {
                ProgressView().controlSize(.small)
            }
            Button { monitor.updateMetadata() } label: {
                Label("Check for updates", systemImage: "arrow.down.circle")
            }
            .disabled(monitor.isBusy || !allowsOperations)
            .help("Run brew update to fetch the latest formula and cask definitions")
            Button { monitor.reload() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(monitor.isBusy || !allowsOperations)
                .help("Relist installed packages")
                .accessibilityLabel("Relist Homebrew packages")
            Button { confirmUpgradeAll = true } label: {
                Label("Upgrade all (\(monitor.upgradable.count))", systemImage: "arrow.up.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(monitor.isBusy || monitor.upgradable.isEmpty || !allowsOperations)
            .help("Upgrade every outdated package except self-updating, unversioned, pinned, or running ones")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch monitor.availability {
        case .notInstalled:
            EmptyPageMessage(
                systemImage: "mug",
                title: "Homebrew is not installed",
                message: "KillSwitch looks for brew in /opt/homebrew and /usr/local. It does not install or manage Homebrew itself."
            )
        case .unknown where monitor.packages.isEmpty:
            EmptyPageMessage(systemImage: "mug", title: "Loading Homebrew", message: "Listing installed formulae and casks…")
        default:
            packageList
        }
    }

    private var packageList: some View {
        let rows = TableQuery(search: search, fields: HomebrewTableFields.all)
            .apply(to: monitor.packages.filter(scope.includes), sorting: sorting, identity: \.id)
        return VStack(alignment: .leading, spacing: 10) {
            if let operation = monitor.activeOperation {
                NoticeBanner(message: "\(operation)… Homebrew is running in the background.", systemImage: "hourglass", color: Theme.accent)
            }
            if let error = monitor.errorMessage {
                NoticeBanner(message: error, dismiss: monitor.clearError)
            }
            if let transcript = monitor.transcript {
                transcriptView(transcript)
            }
            TableSearchControls(search: $search, fields: HomebrewTableFields.all, prompt: "Search packages, or outdated = yes",
                                resetAdditional: { scope = .all })
            HStack {
                Picker("Show", selection: $scope) {
                    ForEach(HomebrewScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                TableSortControls(fields: HomebrewTableFields.all, sorting: $sorting)
                Spacer()
                Text("\(rows.count) of \(monitor.packages.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Table(rows, selection: $selection, sortOrder: tableSortOrder($sorting)) {
                TableColumn("Package", sortUsing: TableComparator(field: HomebrewTableFields.name)) { package in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(package.displayName).font(.system(size: 12, weight: .medium))
                        Text(package.summary ?? package.fullName)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .help(package.fullName)
                }
                .width(min: 180, ideal: 260)
                TableColumn("Type", sortUsing: TableComparator(field: HomebrewTableFields.kind)) { Text($0.kind.title) }
                    .width(60)
                TableColumn("Installed", sortUsing: TableComparator(field: HomebrewTableFields.installed)) {
                    Text($0.installedVersion ?? "—").font(.system(size: 11, design: .monospaced))
                }
                .width(min: 70, ideal: 100)
                TableColumn("Latest", sortUsing: TableComparator(field: HomebrewTableFields.latest)) {
                    Text($0.latestVersion ?? "—").font(.system(size: 11, design: .monospaced))
                }
                .width(min: 70, ideal: 100)
                TableColumn("Status") { status(for: $0) }
                    .width(min: 110, ideal: 140)
                TableColumn("Actions") { actions(for: $0) }
                    .width(150)
            }
            .overlay {
                if rows.isEmpty && !monitor.isLoading {
                    Text(monitor.packages.isEmpty ? "No Homebrew packages are installed." : "No matching packages. Change or reset the filters.")
                        .foregroundColor(.secondary)
                }
            }
            Text("Upgrades and removals run brew in the background with automatic metadata updates turned off, so they act on the versions listed here. Use Check for updates to run brew update first. Self-updating casks are always skipped; their apps update themselves. Casks whose apps are running are skipped until you quit them.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private func status(for package: HomebrewPackage) -> some View {
        HStack(spacing: 4) {
            if package.autoUpdates {
                StatusBadge(title: "Updates itself", color: Theme.diskCleanupAccent, systemImage: "arrow.triangle.2.circlepath")
            } else if package.isOutdated, monitor.runningCasks?.contains(package.fullName) == true {
                StatusBadge(title: "Running", color: .orange, systemImage: "play.circle.fill")
                    .help("Quit \(package.displayName) to upgrade it; Homebrew replaces the app bundle while it runs.")
            } else if package.isOutdated {
                StatusBadge(title: "Outdated", color: .orange, systemImage: "arrow.up.circle.fill")
            } else {
                StatusBadge(title: "Up to date", color: .green)
            }
            if package.isPinned { StatusBadge(title: "Pinned", color: .white.opacity(0.6), systemImage: "pin.fill") }
            if package.isDeprecated || package.isDisabled {
                StatusBadge(title: package.isDisabled ? "Disabled" : "Deprecated", color: .red)
            }
        }
    }

    private func actions(for package: HomebrewPackage) -> some View {
        HStack(spacing: 6) {
            Button("Upgrade") { monitor.upgrade(package) }
                .controlSize(.small)
                .disabled(monitor.restriction(for: package) != nil || monitor.isBusy || !allowsOperations)
                .help(monitor.restriction(for: package) ?? "Upgrade \(package.displayName) to \(package.latestVersion ?? "the latest version")")
                .accessibilityLabel("Upgrade \(package.displayName)")
            Button("Uninstall", role: .destructive) { pendingUninstall = package }
                .controlSize(.small)
                .disabled(monitor.isBusy || !allowsOperations)
                .help("Remove \(package.displayName) with brew uninstall")
                .accessibilityLabel("Uninstall \(package.displayName)")
        }
    }

    private func transcriptView(_ transcript: HomebrewTranscript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(transcript.failure == nil ? "Last Homebrew command finished" : "Last Homebrew command failed",
                      systemImage: transcript.failure == nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(transcript.failure == nil ? .green : .red)
                Spacer()
                Button("Dismiss") { monitor.dismissTranscript() }
                    .controlSize(.small)
            }
            ScrollView {
                Text(transcript.text.isEmpty ? "No output." : transcript.text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
    }

    private var upgradeAllMessage: String {
        let skipped = monitor.outdated.filter { monitor.restriction(for: $0) != nil }
        var text = "Runs brew upgrade for \(monitor.upgradable.map(\.displayName).prefix(8).joined(separator: ", "))"
        if monitor.upgradable.count > 8 { text += ", and \(monitor.upgradable.count - 8) more" }
        text += "."
        if !skipped.isEmpty {
            text += " Skipped: \(skipped.count) self-updating, unversioned, pinned, or running package(s)."
        }
        return text
    }
}
