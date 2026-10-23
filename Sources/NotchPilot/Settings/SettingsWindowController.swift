import AppKit
import SwiftUI

/// Owns the "NotchPilot Settings" window: a standard titled window with only the close button
/// enabled (HIG › Settings: dim the minimize and maximize buttons) and a fixed size.
///
/// The app stays an `.accessory` app (no Dock icon). Opening Settings activates it so the
/// window can take text input; the hidden main menu (see `MainMenu`) supplies the Edit
/// commands, so pasting an API key with Command-V works. Closing the window deactivates the
/// app, which hands focus back to the app the person was using.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: AssistantSettingsStore
    private var window: NSWindow?

    init(store: AssistantSettingsStore) {
        self.store = store
    }

    func show() {
        let window = window ?? makeWindow()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "NotchPilot Settings"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Leave nothing half-typed in memory: the view (and its key drafts) is rebuilt next time.
        window?.contentViewController = nil
        window = nil
        NSApp.deactivate()
    }
}
