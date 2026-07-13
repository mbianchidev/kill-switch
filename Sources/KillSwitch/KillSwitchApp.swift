import SwiftUI
import AppKit
import KeepAwakeCore

@main
struct KillSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)
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
    private let keepAwakeManager = KeepAwakeManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let statusItem else { return }

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "bolt.slash", accessibilityDescription: "KillSwitch")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "KillSwitch"
        }

        let menu = NSMenu()
        let keepAwakeItem = NSMenuItem(title: "Keep Mac Awake", action: nil, keyEquivalent: "")
        keepAwakeItem.submenu = makeKeepAwakeMenu()
        menu.addItem(keepAwakeItem)
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
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
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
    }

    @objc private func showMainWindow() {
        captureMainWindow()
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hideMainWindow() {
        mainWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        keepAwakeManager.deactivate()
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideMainWindow()
        return false
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
