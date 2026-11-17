import SwiftUI
import AppKit
import KeepAwakeCore
import SystemMetricsCore

struct KillSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("KillSwitch", id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 650)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            DiagnosticsCommands()
        }
    }
}

/// Manages app lifecycle plus the menu bar (tray) status item.
///
/// Closing the main window hides it and drops the app to `.accessory` so it
/// lives only in the menu bar (like Caffeine). Re-showing restores the window
/// and the `.regular` (Dock) policy. The app only fully quits via the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private weak var mainWindow: NSWindow?
    private var lastWindowVisibility: Bool?
    private let keepAwakeManager = KeepAwakeManager.shared
    private let screenTimeMonitor = ScreenTimeMonitor.shared
    private var storageVolume: SystemVolume?
    private var storageIconPercent: Int?
    private var storageTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppIconSetup.apply()
        NSApp.activate(ignoringOtherApps: true)
        screenTimeMonitor.start()
        ResourceMonitor.shared.start()
        FolderSizeMonitor.shared.start()
        MaintenanceMonitor.shared.start()
        keepAwakeManager.onStateChange = { [weak self] _ in
            self?.updateStatusItem()
        }
        setupStatusItem()
        if !keepAwakeManager.activatePreferredOnLaunch(),
           let message = keepAwakeManager.errorMessage {
            showKeepAwakeError(message)
        }
        DispatchQueue.main.async { [weak self] in
            self?.captureMainWindow()
            AppStartupConfirmation.applicationDidFinishLaunching()
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateStatusItem()
        startStorageUpdates()
    }

    /// Reads the startup volume's capacity every minute, off the main thread.
    private func startStorageUpdates() {
        refreshStorage()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStorage() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        storageTimer = timer
    }

    private func refreshStorage() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let volume = SystemDetailsReader.startupVolume()
            DispatchQueue.main.async {
                guard let self else { return }
                self.storageVolume = volume
                self.updateStatusIcon()
            }
        }
    }

    /// Redraws the icon only when the rounded used percentage or its availability changes.
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let fraction = storageVolume?.usedFraction
        let percent = fraction.map(StatusItemIcon.percent)
        if button.image == nil || percent != storageIconPercent {
            button.image = StatusItemIcon.image(usedFraction: fraction)
            storageIconPercent = percent
        }
        button.toolTip = StatusItemIcon.toolTip(for: storageVolume)
    }

    private func updateStatusItem() {
        guard let statusItem else { return }
        updateStatusIcon()

        let menu = NSMenu()
        let keepAwakeItem = NSMenuItem(title: "Keep Mac Awake", action: nil, keyEquivalent: "")
        keepAwakeItem.submenu = makeKeepAwakeMenu()
        menu.addItem(keepAwakeItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Generate Spindump…", action: #selector(generateSpindump)))
        menu.addItem(
            menuItem(
                title: "Run System Diagnostics…",
                action: #selector(runSystemDiagnostics),
                keyEquivalent: "d",
                modifiers: [.command, .shift]
            )
        )
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Show KillSwitch", action: #selector(showMainWindow)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit KillSwitch", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func makeKeepAwakeMenu() -> NSMenu {
        let menu = NSMenu()

        if keepAwakeManager.activeDuration != nil {
            menu.addItem(menuItem(title: "Deactivate", action: #selector(deactivateKeepAwake)))
            menu.addItem(.separator())
        }

        for duration in KeepAwakeDuration.allCases {
            let item = menuItem(title: duration.label, action: #selector(activateKeepAwake(_:)))
            item.representedObject = NSNumber(value: duration.rawValue)
            item.state = keepAwakeManager.activeDuration == duration ? .on : .off
            menu.addItem(item)
        }

        return menu
    }

    private func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if !keyEquivalent.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }

    @objc private func activateKeepAwake(_ sender: NSMenuItem) {
        guard
            let rawValue = (sender.representedObject as? NSNumber)?.intValue,
            let duration = KeepAwakeDuration(rawValue: rawValue)
        else {
            showKeepAwakeError("The selected keep-awake duration is invalid.")
            return
        }

        if !keepAwakeManager.activate(for: duration),
           let message = keepAwakeManager.errorMessage {
            showKeepAwakeError(message)
        }
    }

    @objc private func deactivateKeepAwake() {
        keepAwakeManager.deactivate()
    }

    @objc private func generateSpindump() {
        showMainWindow()
        NotificationCenter.default.post(name: .showDiagnosticsTab, object: nil)
        DiagnosticsController.shared.generateSpindump()
    }

    @objc private func runSystemDiagnostics() {
        showMainWindow()
        NotificationCenter.default.post(name: .showDiagnosticsTab, object: nil)
        DiagnosticsController.shared.runSystemDiagnostics()
    }

    private func showKeepAwakeError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Keep Mac Awake could not start"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: Window handling

    private func captureMainWindow() {
        if mainWindow == nil {
            mainWindow = NSApp.windows.first { window in
                let name = String(describing: type(of: window))
                return window.canBecomeMain && !name.contains("StatusBar")
            }
        }
        mainWindow?.delegate = self
        updateWindowVisibility()
    }

    @objc private func showMainWindow() {
        captureMainWindow()
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateWindowVisibility()
    }

    private func hideMainWindow() {
        mainWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        updateWindowVisibility()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        storageTimer?.invalidate()
        screenTimeMonitor.stop()
        FolderSizeMonitor.shared.stop()
        MaintenanceMonitor.shared.stop()
        SystemHealthMonitor.shared.shutdown()
        ResourceMonitor.shared.shutdown()
        keepAwakeManager.deactivate()
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideMainWindow()
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) { updateWindowVisibility() }

    func windowDidDeminiaturize(_ notification: Notification) { updateWindowVisibility() }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateWindowVisibility() }

    private func updateWindowVisibility() {
        let visible = mainWindow.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        guard lastWindowVisibility != visible else { return }
        lastWindowVisibility = visible
        AppWindowVisibility.setVisible(visible)
        SystemHealthMonitor.shared.setWindowVisible(visible)
        ResourceMonitor.shared.setWindowVisible(visible)
        NotificationCenter.default.post(name: .killSwitchWindowVisibility, object: visible)
    }

    // MARK: NSApplicationDelegate

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
}
