import AppKit
import SwiftUI
import SystemMetricsCore

struct ActivityProcessMenu: NSViewRepresentable {
    let title: String
    let processes: [ActivityProcessDescriptor]
    let liveIdentities: Set<ActivityProcessIdentity>
    @Binding var selection: ActivityProcessIdentity?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.cell?.lineBreakMode = .byTruncatingTail
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        context.coordinator.reset(menu)
        button.menu = menu
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.menu?.item(at: 0)?.title = title
        button.setAccessibilityLabel(title)
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: ActivityProcessMenu
        private var isTracking = false

        private final class Choice: NSObject {
            let identity: ActivityProcessIdentity?
            init(_ identity: ActivityProcessIdentity?) { self.identity = identity }
        }

        init(_ parent: ActivityProcessMenu) { self.parent = parent }

        func reset(_ menu: NSMenu) {
            menu.removeAllItems()
            menu.addItem(NSMenuItem(title: parent.title, action: nil, keyEquivalent: ""))
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            reset(menu)
            addChoice(title: "Entire Mac", identity: nil, to: menu)
            menu.addItem(.separator())
            for process in parent.processes {
                let started = Date(timeIntervalSince1970: Double(process.identity.startTime) / 1_000_000)
                let exited = parent.liveIdentities.contains(process.id) ? "" : " [exited]"
                let title = "\(process.name) (\(process.identity.pid), \(started.formatted(date: .omitted, time: .standard)))\(exited)"
                addChoice(title: title, identity: process.id, to: menu)
            }
        }

        func menuWillOpen(_ menu: NSMenu) {
            isTracking = true
        }

        func menuDidClose(_ menu: NSMenu) {
            isTracking = false
            // AppKit sends the selected action after closing the menu.
            DispatchQueue.main.async { [weak self, weak menu] in
                guard let self, let menu, !self.isTracking else { return }
                self.reset(menu)
            }
        }

        private func addChoice(title: String, identity: ActivityProcessIdentity?, to menu: NSMenu) {
            let item = NSMenuItem(title: title, action: #selector(selectProcess(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Choice(identity)
            item.state = parent.selection == identity ? .on : .off
            menu.addItem(item)
        }

        @objc private func selectProcess(_ item: NSMenuItem) {
            guard let choice = item.representedObject as? Choice else {
                fputs("KillSwitch could not read the selected history process.\n", stderr)
                return
            }
            parent.selection = choice.identity
        }
    }
}
