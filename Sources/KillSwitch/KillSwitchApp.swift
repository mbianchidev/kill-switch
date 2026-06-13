import SwiftUI
import AppKit

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        setupStatusItem()
        DispatchQueue.main.async { [weak self] in
            self?.captureMainWindow()
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "bolt.slash", accessibilityDescription: "KillSwitch")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "KillSwitch"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show KillSwitch", action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit KillSwitch", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items where entry.action != nil {
            entry.target = self
        }
        item.menu = menu
        statusItem = item
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
