import SwiftUI
import AppKit

@main
struct DisplayBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We use Settings as a dummy scene since the real UI is the NSPopover from AppDelegate
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let displayManager = DisplayManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock
        NSApp.setActivationPolicy(.accessory)

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "DisplayBuddy")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create popover with SwiftUI content
        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView(manager: displayManager))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            displayManager.refreshDisplays()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Bring popover to front
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
