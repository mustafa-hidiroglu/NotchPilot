import AppKit
import NotchPilotCore
import SwiftUI

/// Owns the Settings window: a standard titled window with only the close button enabled
/// and a fixed-size pane per toolbar item (HIG › Settings › macOS: noncustomizable toolbar
/// that shows the active pane, title follows the pane, most recently viewed pane restored,
/// minimize and maximize dimmed).
///
/// The app stays an `.accessory` app (no Dock icon). Opening Settings activates it so the
/// window can take text input; the hidden main menu (see `MainMenu`) supplies the Edit
/// commands, so pasting an API key with Command-V works. Closing the window deactivates the
/// app, which hands focus back to the app the person was using.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static let lastPaneKey = "SettingsLastPane"

    private let store: AssistantSettingsStore
    private let hotKeys: HotKeyCenter
    /// Owned by the app delegate (the island uses it too), so downloads continue while
    /// Settings is closed.
    private let speechModels: SpeechModelsController
    private var window: NSWindow?
    private var tabs: SettingsTabViewController?

    init(store: AssistantSettingsStore, speechModels: SpeechModelsController, hotKeys: HotKeyCenter) {
        self.store = store
        self.speechModels = speechModels
        self.hotKeys = hotKeys
    }

    /// Opens Settings at `pane`, or at the pane viewed last.
    func show(pane: SettingsPane? = nil) {
        let window = window ?? makeWindow()
        let target = pane ?? UserDefaults.standard.string(forKey: Self.lastPaneKey).flatMap(SettingsPane.init) ?? .general
        tabs?.select(target)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        tabs.onSelect = { pane in UserDefaults.standard.set(pane.rawValue, forKey: Self.lastPaneKey) }
        for pane in SettingsPane.allCases {
            let controller = NSHostingController(rootView: AnyView(content(for: pane)))
            controller.sizingOptions = [.preferredContentSize]
            controller.title = pane.title
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.systemImage, accessibilityDescription: nil)
            item.identifier = pane.rawValue
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        self.window = window
        self.tabs = tabs
        return window
    }

    @ViewBuilder private func content(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettingsPane(store: store, hotKeys: hotKeys)
        case .assistant: AssistantSettingsPane(store: store)
        case .speech: SpeechSettingsPane(store: store, models: speechModels)
        }
    }

    func windowWillClose(_ notification: Notification) {
        store.persistNow()
        hotKeys.setSuspended(false)   // in case the window closed mid-recording
        // Leave nothing half-typed in memory: the views (and their key drafts) are rebuilt next time.
        window?.contentViewController = nil
        window = nil
        tabs = nil
        NSApp.deactivate()
    }
}

/// Toolbar-style tab controller that sizes the window to each pane and titles it after the
/// pane, keeping the window's top edge in place.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    var onSelect: (SettingsPane) -> Void = { _ in }

    func select(_ pane: SettingsPane) {
        guard let index = tabViewItems.firstIndex(where: { $0.identifier as? String == pane.rawValue }) else { return }
        if selectedTabViewItemIndex == index { fitWindow(to: tabViewItems[index]) } else { selectedTabViewItemIndex = index }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let tabViewItem else { return }
        fitWindow(to: tabViewItem)
        if let id = tabViewItem.identifier as? String, let pane = SettingsPane(rawValue: id) { onSelect(pane) }
    }

    private func fitWindow(to item: NSTabViewItem) {
        guard let window = view.window, let controller = item.viewController else { return }
        window.title = item.label
        let size = controller.preferredContentSize == .zero ? controller.view.fittingSize : controller.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let target = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - size.height,
                                                            width: size.width, height: size.height))
        guard target != window.frame else { return }
        let animate = window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(target, display: true, animate: animate)
    }
}
