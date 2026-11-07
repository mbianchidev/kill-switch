import AppKit
import SwiftUI
import SystemMetricsCore
import os

enum AppWindowVisibility {
    private static let state = OSAllocatedUnfairLock(initialState: true)
    static var isVisible: Bool { state.withLock { $0 } }
    static func setVisible(_ visible: Bool) { state.withLock { $0 = visible } }
}

enum MainTab: String, CaseIterable, Identifiable {
    case dashboard, resources, memory, disk, network, energy
    case system, battery, thermal, devServers, connections, openFiles
    case startup, diskCleanup, cleanup, watchdog, screenTime, diagnostics, keepAwake, updates

    var id: Self { self }

    static let sections: [(title: String, pages: [MainTab])] = [
        ("Overview", [.dashboard, .system]),
        ("Performance", [.resources, .memory, .disk, .network, .energy]),
        ("Investigate", [.devServers, .connections, .openFiles]),
        ("Manage", [.startup, .diskCleanup, .cleanup, .watchdog]),
        ("Your Mac", [.battery, .thermal, .screenTime, .keepAwake]),
        ("KillSwitch", [.diagnostics, .updates])
    ]

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .resources: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk activity"
        case .network: return "Network traffic"
        case .energy: return "Energy"
        case .system: return "System"
        case .battery: return "Battery"
        case .thermal: return "Thermal"
        case .devServers: return "Dev servers"
        case .connections: return "Connections"
        case .openFiles: return "Open files"
        case .startup: return "Startup"
        case .diskCleanup: return "Disk cleanup"
        case .cleanup: return "Dev cleanup"
        case .watchdog: return "CPU watchdog"
        case .screenTime: return "Screen time"
        case .diagnostics: return "Diagnostics"
        case .keepAwake: return "Keep awake"
        case .updates: return "Updates"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .resources: return "cpu"
        case .memory: return "memorychip"
        case .disk, .diskCleanup: return "internaldrive"
        case .network: return "network"
        case .energy: return "bolt"
        case .system: return "desktopcomputer"
        case .battery: return "battery.100"
        case .thermal: return "thermometer.medium"
        case .devServers: return "server.rack"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .openFiles: return "doc.text.magnifyingglass"
        case .startup: return "power"
        case .cleanup: return "trash"
        case .watchdog: return "exclamationmark.triangle"
        case .screenTime: return "figure.walk.motion"
        case .diagnostics: return "stethoscope"
        case .keepAwake: return "cup.and.saucer.fill"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }

    var accent: Color {
        switch self {
        case .resources, .network, .connections, .devServers: return Theme.cpuUser
        case .memory, .battery, .screenTime, .keepAwake: return Theme.memory
        case .energy, .thermal, .watchdog: return Theme.energy
        case .disk, .diskCleanup: return Theme.diskOccupied
        default: return Theme.accent
        }
    }

    var metric: ResourceMetric? {
        switch self {
        case .resources: return .cpu
        case .memory: return .memory
        case .disk: return .disk
        case .network: return .network
        case .energy: return .energy
        default: return nil
        }
    }

    func requiresCleanupConfirmation(autoKillEnabled: Bool) -> Bool {
        self == .cleanup && autoKillEnabled
    }
}

private struct WindowVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

private struct LiveOperationsKey: EnvironmentKey {
    static let defaultValue = true
}

private struct PageVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

private struct ProcessInspectorKey: EnvironmentKey {
    static let defaultValue: (@MainActor (ActivityProcessDescriptor) -> Void)? = nil
}

private struct PageNavigationKey: EnvironmentKey {
    static let defaultValue: (@MainActor (MainTab) -> Void)? = nil
}

extension EnvironmentValues {
    var isKillSwitchWindowVisible: Bool {
        get { self[WindowVisibilityKey.self] }
        set { self[WindowVisibilityKey.self] = newValue }
    }

    var allowsLiveOperations: Bool {
        get { self[LiveOperationsKey.self] }
        set { self[LiveOperationsKey.self] = newValue }
    }

    var isKillSwitchPageVisible: Bool {
        get { self[PageVisibilityKey.self] }
        set { self[PageVisibilityKey.self] = newValue }
    }

    var inspectProcess: (@MainActor (ActivityProcessDescriptor) -> Void)? {
        get { self[ProcessInspectorKey.self] }
        set { self[ProcessInspectorKey.self] = newValue }
    }

    var navigatePage: (@MainActor (MainTab) -> Void)? {
        get { self[PageNavigationKey.self] }
        set { self[PageNavigationKey.self] = newValue }
    }
}

extension Notification.Name {
    static let killSwitchWindowVisibility = Notification.Name("KillSwitch.windowVisibility")
}

struct AppSidebar: View {
    @Binding var selection: MainTab?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.slash")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(Theme.accent)
                    .frame(width: 34, height: 38)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("KillSwitch")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("Know. Inspect. Act.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            Divider()
            List(selection: $selection) {
                ForEach(MainTab.sections, id: \.title) { section in
                    Section {
                        ForEach(section.pages) { page in
                            Label {
                                Text(page.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.88))
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: page.icon)
                                    .foregroundColor(contrast == .increased ? .white : page.accent)
                                    .frame(width: 19)
                            }
                            .padding(.vertical, 3)
                            .tag(page)
                            .help(page == .cleanup ? "Opening Dev cleanup can start automatic termination." : page.title)
                        }
                    } header: {
                        Text(section.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("KillSwitch pages")
            Divider()
            Label("Private, local history", systemImage: "lock")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
                .padding(14)
        }
        .background(Theme.sidebar)
    }
}

// Native tabs retain visited page state while only the selected controller is visible.
struct RetainedPageHost: NSViewControllerRepresentable {
    let selection: MainTab
    let content: AnyView

    func makeNSViewController(context: Context) -> RetainedPageController {
        let controller = RetainedPageController()
        controller.show(selection, content: content)
        return controller
    }

    func updateNSViewController(_ controller: RetainedPageController, context: Context) {
        controller.show(selection, content: content)
    }
}

final class RetainedPageController: NSTabViewController {
    private var pages: [MainTab: NSHostingController<AnyView>] = [:]
    private var contents: [MainTab: AnyView] = [:]

#if KILLSWITCH_PERFORMANCE_PROBE
    var performancePageCount: Int { pages.count }
#endif

    func show(_ page: MainTab, content: AnyView) {
        tabStyle = .unspecified
        tabView.tabViewType = .noTabsNoBorder
        tabView.drawsBackground = false
        contents[page] = content
        let visibleContent = AnyView(content.environment(\.isKillSwitchPageVisible, true))
        let hosting: NSHostingController<AnyView>
        if let existing = pages[page] {
            hosting = existing
            hosting.rootView = visibleContent
        } else {
            hosting = NSHostingController(rootView: visibleContent)
            pages[page] = hosting
            addTabViewItem(NSTabViewItem(viewController: hosting))
        }
        guard let index = tabViewItems.firstIndex(where: { $0.viewController === hosting }) else {
            preconditionFailure("The retained page must have a native tab item.")
        }
        if selectedTabViewItemIndex != index { selectedTabViewItemIndex = index }
        for (otherPage, controller) in pages where otherPage != page {
            if let otherContent = contents[otherPage] {
                controller.rootView = AnyView(otherContent.environment(\.isKillSwitchPageVisible, false))
            }
            controller.view.setFrameSize(.zero)
            controller.view.layoutSubtreeIfNeeded()
        }
    }
}

struct InspectProcessButton: View {
    let process: ActivityProcessDescriptor?
    @Environment(\.inspectProcess) private var inspect

    var body: some View {
        Button {
            if let process { inspect?(process) }
        } label: {
            Image(systemName: "info.circle")
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(process == nil || inspect == nil)
        .help("Inspect process files and connections")
        .accessibilityLabel(process.map { "Inspect \($0.name), PID \($0.id.pid)" } ?? "Process identity unavailable")
    }
}
