import SoftwareInventoryCore
import SwiftUI

struct SecurityTab: View {
    @ObservedObject var monitor: SecurityMonitor
    @ObservedObject var homebrew: HomebrewMonitor
    @Environment(\.isKillSwitchPageVisible) private var pageVisible
    @Environment(\.allowsLiveOperations) private var allowsOperations
    @Environment(\.navigatePage) private var navigate

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
            ForEach(monitor.checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon(for: check))
                        .foregroundColor(color(for: check))
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title).font(.system(size: 12, weight: .medium))
                        Text(check.detail)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    StatusBadge(title: check.state.rawValue, color: color(for: check))
                }
                .accessibilityElement(children: .combine)
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
            if monitor.updates != nil, items.isEmpty {
                Label("macOS and Apple software are up to date.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
            } else if !items.isEmpty {
                Text("\(security.count) security-relevant update(s) of \(items.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(security.isEmpty ? .white.opacity(0.7) : .orange)
            }
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: item.category.isSecurityRelevant ? "exclamationmark.shield.fill" : "arrow.down.circle")
                        .foregroundColor(item.category.isSecurityRelevant ? .orange : .secondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.title)\(item.version.map { " \($0)" } ?? "")")
                            .font(.system(size: 12, weight: .medium))
                        Text(itemDetail(item))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    StatusBadge(title: item.category.isSecurityRelevant ? "Security" : item.category.rawValue,
                                color: item.category.isSecurityRelevant ? .orange : .secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(item.category.isSecurityRelevant ? Color.orange.opacity(0.1) : Color.white.opacity(0.04)))
                .accessibilityElement(children: .combine)
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
                ForEach(outdated.prefix(12)) { package in
                    HStack {
                        Text(package.displayName).font(.system(size: 12))
                        Text(package.kind.title).font(.system(size: 10)).foregroundColor(.secondary)
                        Spacer()
                        Text("\(package.installedVersion ?? "?") → \(package.latestVersion ?? "?")")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        if !package.canUpgrade {
                            StatusBadge(title: package.autoUpdates ? "Updates itself" : "Skipped", color: .secondary)
                                .help(package.upgradeRestriction ?? "")
                        }
                    }
                }
                if outdated.count > 12 {
                    Text("And \(outdated.count - 12) more on the Homebrew page.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
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

    private func itemDetail(_ item: SoftwareUpdateItem) -> String {
        var parts = [item.category.rawValue]
        if let size = item.sizeBytes { parts.append(formatBytes(size)) }
        if item.requiresRestart { parts.append("restart required") }
        if !item.recommended { parts.append("not recommended by Apple") }
        return parts.joined(separator: " · ")
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
