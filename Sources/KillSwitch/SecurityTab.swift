import SoftwareInventoryCore
import SwiftUI
import TableQueryCore

private enum SecurityCheckFields {
    static let name = TableField<SecurityCheck>.text("protection", title: "Protection", aliases: ["name", "check"]) { $0.title }
    static let state = TableField<SecurityCheck>.text(
        "state", title: "State", values: ["On", "Off", "Unknown"], searchable: false
    ) { $0.state.rawValue }
    static let detail = TableField<SecurityCheck>.text("detail", title: "Detail") { $0.detail }
    static let attention = TableField<SecurityCheck>.boolean("attention", title: "Needs attention") { $0.needsAttention }
    static let recommended = TableField<SecurityCheck>.boolean("recommended", title: "Recommended on") { $0.recommendedOn }
    static let all = [name, state, detail, attention, recommended]
}

private enum SoftwareUpdateFields {
    static let title = TableField<SoftwareUpdateItem>.text("update", title: "Update", aliases: ["title", "name"]) {
        SecurityTab.displayTitle($0)
    }
    static let label = TableField<SoftwareUpdateItem>.text("label", title: "Label") { $0.label }
    static let category = TableField<SoftwareUpdateItem>.text(
        "category", title: "Category", aliases: ["type"],
        values: ["Security response", "macOS update", "macOS upgrade", "Safari update", "Other update"], searchable: false
    ) { $0.category.rawValue }
    static let security = TableField<SoftwareUpdateItem>.boolean("security", title: "Security relevant") {
        $0.category.isSecurityRelevant
    }
    static let size = TableField<SoftwareUpdateItem>.number("size", title: "Size", unit: .bytes) {
        (item: SoftwareUpdateItem) -> Decimal? in item.sizeBytes.map { Decimal($0) }
    }
    static let restart = TableField<SoftwareUpdateItem>.boolean("restart", title: "Restart required") { $0.requiresRestart }
    static let recommended = TableField<SoftwareUpdateItem>.boolean("recommended", title: "Recommended") { $0.recommended }
    static let all = [title, category, size, restart, recommended, security, label]
}

/// An outdated package with whether KillSwitch may upgrade it, read when the table is built.
private struct OutdatedPackageRow: Identifiable {
    let package: HomebrewPackage
    let restriction: String?
    var id: String { package.id }
    var upgradeState: String { restriction == nil ? "Upgradable" : package.autoUpdates ? "Updates itself" : "Skipped" }
}

private enum OutdatedPackageFields {
    static let name = TableField<OutdatedPackageRow>.text("name", title: "Package", aliases: ["token", "formula", "cask"]) {
        $0.package.displayName
    }
    static let fullName = TableField<OutdatedPackageRow>.text("fullName", title: "Homebrew name") { $0.package.fullName }
    static let kind = TableField<OutdatedPackageRow>.text(
        "type", title: "Type", aliases: ["kind"], values: ["Formula", "Cask"], searchable: false
    ) { $0.package.kind.title }
    static let installed = TableField<OutdatedPackageRow>.text("installed", title: "Installed", searchable: false) {
        $0.package.installedVersion
    }
    static let latest = TableField<OutdatedPackageRow>.text("latest", title: "Latest", searchable: false) { $0.package.latestVersion }
    static let upgrade = TableField<OutdatedPackageRow>.text(
        "upgrade", title: "Upgrade", aliases: ["status"], values: ["Upgradable", "Updates itself", "Skipped"], searchable: false
    ) { $0.upgradeState }
    static let all = [name, kind, installed, latest, upgrade, fullName]
}

struct SecurityTab: View {
    @ObservedObject var monitor: SecurityMonitor
    @ObservedObject var homebrew: HomebrewMonitor
    @Environment(\.isKillSwitchPageVisible) private var pageVisible
    @Environment(\.allowsLiveOperations) private var allowsOperations
    @Environment(\.navigatePage) private var navigate
    // Retained without observing; only the tables observe it.
    @State private var tableStates = TableStateStore()

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(page: .security, subtitle: "macOS protections, available security updates, and outdated Homebrew packages.") {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(monitor.isCheckingPosture || monitor.isListingUpdates || !allowsOperations)
                    .help("Check protections and list updates again")
                    .accessibilityLabel("Refresh security status")
            }
            Divider()
            if pageVisible {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let error = monitor.errorMessage {
                            NoticeBanner(message: error, dismiss: monitor.clearError)
                        }
                        protectionsCard
                        updatesCard
                        packagesCard
                        Text("KillSwitch reads these settings without administrator access and never changes them. Install macOS updates from Software Update; upgrade Homebrew packages from the Homebrew page.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                }
            }
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

    private func refresh() {
        monitor.refreshPosture()
        monitor.listUpdates(scan: false)
        homebrew.reload()
    }

    private var protectionsCard: some View {
        securityCard("Protections", icon: "shield.lefthalf.filled", trailing: monitor.isCheckingPosture ? "Checking…" : nil) {
            if monitor.checks.isEmpty {
                Text(monitor.isCheckingPosture ? "Reading macOS protections…" : "Protections have not been checked yet.")
                    .foregroundColor(.secondary)
            }
            if !monitor.checks.isEmpty {
                EmbeddedDataTable(
                    monitor.checks, fields: SecurityCheckFields.all,
                    sortedBy: TableComparator(field: SecurityCheckFields.attention, order: .reverse),
                    state: tableStates, key: "protections",
                    identity: { $0.id.rawValue }, prompt: "Search protections, or state = Off"
                ) {
                    TableColumn("Protection", sortUsing: TableComparator(field: SecurityCheckFields.name)) { check in
                        Label {
                            Text(check.title).font(.system(size: 12, weight: .medium))
                        } icon: {
                            Image(systemName: icon(for: check)).foregroundColor(color(for: check))
                        }
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn("State", sortUsing: TableComparator(field: SecurityCheckFields.state)) { check in
                        StatusBadge(title: check.state.rawValue, color: color(for: check))
                    }
                    .width(min: 60, ideal: 80)
                    TableColumn("Detail", sortUsing: TableComparator(field: SecurityCheckFields.detail)) { check in
                        Text(check.detail).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).help(check.detail)
                    }
                    .width(min: 200, ideal: 420)
                }
            }
        }
    }

    private var updatesCard: some View {
        let items = monitor.updates?.items ?? []
        let security = items.filter(\.category.isSecurityRelevant)
        return securityCard("macOS updates", icon: "applelogo", trailing: nil) {
            HStack(spacing: 8) {
                if monitor.isListingUpdates {
                    ProgressView().controlSize(.small)
                    Text(monitor.isFullScan ? "Scanning with Apple. This can take a few minutes…" : "Reading the last update scan…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text(scanDescription)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Scan now") { monitor.listUpdates(scan: true) }
                    .controlSize(.small)
                    .disabled(monitor.isListingUpdates || !allowsOperations)
                    .help("Run softwareupdate --list to contact Apple for new updates")
                Button("Open Software Update") { monitor.openSoftwareUpdate() }
                    .controlSize(.small)
            }
            if let error = monitor.updatesError {
                NoticeBanner(message: error)
            }
            ForEach(monitor.updates?.warnings ?? [], id: \.self) { warning in
                NoticeBanner(message: "softwareupdate reported: \(warning)")
            }
            let listingIsClean = monitor.updatesError == nil && (monitor.updates?.warnings.isEmpty ?? false)
            if monitor.updates != nil, items.isEmpty, listingIsClean {
                Label("macOS and Apple software are up to date.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
            } else if monitor.updates != nil, items.isEmpty {
                Text("The update status is unavailable until a listing completes without errors.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else if !items.isEmpty {
                if monitor.updatesError != nil {
                    Text("Showing the previous listing; it may be out of date.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Text("\(security.count) security-relevant update(s) of \(items.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(security.isEmpty ? .white.opacity(0.7) : .orange)
            }
            if !items.isEmpty {
                EmbeddedDataTable(
                    items, fields: SoftwareUpdateFields.all,
                    sortedBy: TableComparator(field: SoftwareUpdateFields.security, order: .reverse),
                    state: tableStates, key: "updates",
                    identity: \.id, prompt: "Search updates, or security = yes"
                ) {
                    TableColumn("Update", sortUsing: TableComparator(field: SoftwareUpdateFields.title)) { item in
                        Label {
                            Text(Self.displayTitle(item)).font(.system(size: 12, weight: .medium))
                                .copyOnClick(item.label, label: "update label")
                        } icon: {
                            Image(systemName: item.category.isSecurityRelevant ? "exclamationmark.shield.fill" : "arrow.down.circle")
                                .foregroundColor(item.category.isSecurityRelevant ? .orange : .secondary)
                        }
                    }
                    .width(min: 180, ideal: 300)
                    TableColumn("Category", sortUsing: TableComparator(field: SoftwareUpdateFields.category)) { item in
                        StatusBadge(title: item.category.rawValue, color: item.category.isSecurityRelevant ? .orange : .secondary)
                    }
                    .width(min: 90, ideal: 130)
                    TableColumn("Size", sortUsing: TableComparator(field: SoftwareUpdateFields.size)) { item in
                        Text(item.sizeBytes.map(formatBytes) ?? "—").font(.system(size: 11, design: .monospaced))
                    }
                    .width(min: 60, ideal: 80)
                    TableColumn("Restart", sortUsing: TableComparator(field: SoftwareUpdateFields.restart)) { item in
                        Text(item.requiresRestart ? "Required" : "No")
                    }
                    .width(min: 50, ideal: 70)
                    TableColumn("Recommended", sortUsing: TableComparator(field: SoftwareUpdateFields.recommended)) { item in
                        Text(item.recommended ? "Yes" : "No")
                    }
                    .width(min: 60, ideal: 95)
                }
            }
            Text("Security responses, updates within your installed macOS version, and Safari updates are highlighted because Apple ships security fixes in them. Major upgrades and other software are listed without highlighting.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var packagesCard: some View {
        securityCard("Homebrew packages", icon: "mug.fill", trailing: nil) {
            switch homebrew.availability {
            case .notInstalled:
                Text("Homebrew is not installed.").foregroundColor(.secondary)
            case .unknown:
                Text("Listing Homebrew packages…").foregroundColor(.secondary)
            case .installed where !homebrew.inventoryLoaded:
                Text(homebrew.isLoading ? "Listing Homebrew packages…" : "Homebrew packages could not be listed, so their update status is unknown.")
                    .foregroundColor(.secondary)
                if let error = homebrew.errorMessage {
                    NoticeBanner(message: error)
                }
            case .installed:
                let outdated = homebrew.outdated
                let upgradable = homebrew.upgradable
                HStack {
                    Text(outdated.isEmpty
                         ? "All Homebrew packages are up to date."
                         : "\(outdated.count) outdated package(s); \(upgradable.count) can be upgraded from KillSwitch.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(outdated.isEmpty ? .green : .orange)
                    Spacer()
                    Button("Review in Homebrew") { navigate?(.homebrew) }
                        .controlSize(.small)
                }
                if let error = homebrew.errorMessage {
                    NoticeBanner(message: error)
                }
                if !outdated.isEmpty {
                    EmbeddedDataTable(
                        outdated.map { OutdatedPackageRow(package: $0, restriction: homebrew.restriction(for: $0)) },
                        fields: OutdatedPackageFields.all, sortedBy: TableComparator(field: OutdatedPackageFields.name),
                        state: tableStates, key: "packages",
                        identity: \.id, prompt: "Search packages, or upgrade = Upgradable"
                    ) {
                        TableColumn("Package", sortUsing: TableComparator(field: OutdatedPackageFields.name)) { row in
                            Text(row.package.displayName).font(.system(size: 12))
                                .copyOnClick(row.package.fullName, label: "Homebrew name")
                        }
                        .width(min: 120, ideal: 200)
                        TableColumn("Type", sortUsing: TableComparator(field: OutdatedPackageFields.kind)) { row in
                            Text(row.package.kind.title)
                        }
                        .width(min: 44, ideal: 60)
                        TableColumn("Version", sortUsing: TableComparator(field: OutdatedPackageFields.installed)) { row in
                            Text("\(row.package.installedVersion ?? "?") → \(row.package.latestVersion ?? "?")")
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help("Installed \(row.package.installedVersion ?? "unknown"), latest \(row.package.latestVersion ?? "unknown")")
                        }
                        .width(min: 120, ideal: 210)
                        TableColumn("Upgrade", sortUsing: TableComparator(field: OutdatedPackageFields.upgrade)) { row in
                            StatusBadge(title: row.upgradeState, color: row.restriction == nil ? .orange : .secondary)
                                .help(row.restriction ?? "KillSwitch can upgrade this package from the Homebrew page.")
                        }
                        .width(min: 80, ideal: 110)
                    }
                }
                Text("Homebrew does not label which upgrades fix vulnerabilities, so every outdated package is listed. The list uses Homebrew's local definitions; Check for updates on the Homebrew page refreshes them.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var scanDescription: String {
        var parts: [String] = []
        if let date = monitor.lastSystemUpdateCheck {
            parts.append("macOS last checked \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        if let date = monitor.updatesListedAt {
            parts.append("listed \(date.formatted(date: .omitted, time: .shortened))")
        }
        return parts.isEmpty ? "Updates have not been listed yet." : parts.joined(separator: " · ")
    }

    /// The update's title with its version, unless the title already includes it.
    static func displayTitle(_ item: SoftwareUpdateItem) -> String {
        item.version.map { item.title.contains($0) ? item.title : "\(item.title) \($0)" } ?? item.title
    }

    private func color(for check: SecurityCheck) -> Color {
        switch check.state {
        case .enabled: return .green
        case .disabled: return check.recommendedOn ? .orange : .secondary
        case .unknown: return .secondary
        }
    }

    private func icon(for check: SecurityCheck) -> String {
        switch check.state {
        case .enabled: return "checkmark.shield.fill"
        case .disabled: return check.recommendedOn ? "exclamationmark.shield.fill" : "shield"
        case .unknown: return "questionmark.circle"
        }
    }

    private func securityCard<Content: View>(
        _ title: String, icon: String, trailing: String?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.accent)
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}
