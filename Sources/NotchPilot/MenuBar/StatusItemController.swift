import AppKit
import NotchPilotCore

/// The compact menu-bar entry. Every island action is also reachable here, which gives
/// keyboard users (Control-F8 / Full Keyboard Access) a complete path (HIG › The menu bar).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        var toggleIsland: () -> Void
        var showControls: () -> Void
        var toggleCapture: () -> Void
        var openPrivacySettings: () -> Void
        var openSettings: () -> Void
        var clearTranscript: () -> Void
        var ask: () -> Void
        var askTitle: () -> String
        /// The global Ask shortcut when it is on and registered, shown on the Ask item.
        var askShortcut: () -> HotKey?
        var hasTranscript: () -> Bool
        /// Sends the transcript for a summary (never automatic; only from this item or the
        /// island's Summarize button).
        var summarize: () -> Void
        var canSummarize: () -> Bool
        /// Provider name for "Summarize with <Provider>".
        var providerName: () -> String
        /// Ask Once / Chat, shown as a checked pair under Ask.
        var askMode: () -> AskMode
        var canChangeMode: () -> Bool
        var setAskMode: (AskMode) -> Void
        var newChat: () -> Void
        var canStartNewChat: () -> Bool
        var isIslandVisible: () -> Bool
        var captureState: () -> CaptureState
        /// Reopens the first-run setup guide.
        var openSetupGuide: () -> Void
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let actions: Actions

    init(actions: Actions) {
        self.actions = actions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false   // enabled state is set explicitly in menuNeedsUpdate
        statusItem.menu = menu
        update(for: .idle)
    }

    /// Reflects capture state in the icon: a filled, distinct symbol while capturing so the
    /// indicator does not rely on colour (template images are monochrome).
    func update(for state: CaptureState) {
        guard let button = statusItem.button else { return }
        let capturing = state.isActive
        let symbol = capturing ? "waveform.circle.fill" : "waveform"
        let description = capturing ? "NotchPilot – capturing system audio" : "NotchPilot"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    // MARK: NSMenuDelegate — rebuilt on open so titles always match the current state.

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = actions.captureState()

        let status = NSMenuItem(title: statusTitle(state), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(item(state.isActive ? "Stop Capture" : "Start Capture", key: "r", action: #selector(toggleCapture)))
        menu.addItem(item("Show Controls", key: "", action: #selector(showControls)))
        menu.addItem(item(actions.isIslandVisible() ? "Hide Island" : "Show Island", key: "", action: #selector(toggleIsland)))
        // Same action as the global shortcut: opens the island with the question field ready
        // (ellipsis: more input follows, HIG › Menus). The shortcut is shown the standard
        // way, right-aligned (HIG › Menus: "a menu item can also display the associated
        // keyboard command"); keys a menu can't draw go in the tooltip instead.
        let ask = item(actions.askTitle() + "…", key: "", action: #selector(askAssistant))
        if let shortcut = actions.askShortcut() {
            if let equivalent = shortcut.menuKeyEquivalent {
                ask.keyEquivalent = equivalent.key
                ask.keyEquivalentModifierMask = equivalent.modifiers
            } else {
                ask.toolTip = "Shortcut: \(shortcut.localizedDisplay)"
            }
        }
        menu.addItem(ask)
        // The island's mode as a checked pair, indented under Ask (HIG › Menus: a checkmark
        // marks the active choice of mutually exclusive items).
        let mode = actions.askMode()
        for (title, value, selector) in [("Ask Once", AskMode.once, #selector(selectAskOnce)),
                                         ("Chat", AskMode.chat, #selector(selectChat))] {
            let modeItem = item(title, key: "", action: selector)
            modeItem.state = mode == value ? .on : .off
            modeItem.indentationLevel = 1
            modeItem.isEnabled = actions.canChangeMode()
            menu.addItem(modeItem)
        }
        // ⌘N is the island's shortcut for it, shown here like any other.
        let newChat = item("New Chat", key: "n", action: #selector(startNewChat))
        newChat.isEnabled = actions.canStartNewChat()
        menu.addItem(newChat)
        // Names where the transcript goes, like "Ask <provider>…" (nothing is sent until chosen).
        let summarize = item("Summarize with \(actions.providerName())", key: "", action: #selector(summarizeTranscript))
        summarize.isEnabled = actions.canSummarize()
        menu.addItem(summarize)
        let clear = item("Clear Transcript", key: "", action: #selector(clearTranscript))
        clear.isEnabled = actions.hasTranscript()
        menu.addItem(clear)
        menu.addItem(.separator())
        // Ellipsis: opens a window that needs more input (HIG › Menus).
        menu.addItem(item("Settings…", key: ",", action: #selector(openSettings)))
        menu.addItem(item("Setup Guide…", key: "", action: #selector(openSetupGuide)))
        menu.addItem(item("Open Privacy Settings", key: "", action: #selector(openPrivacySettings)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NotchPilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(_ title: String, key: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func statusTitle(_ state: CaptureState) -> String {
        switch state {
        case .idle: "System Audio Capture Is Off"
        case .starting: "Starting Capture…"
        case .running(let format): "Capturing System Audio (\(format.description))"
        case .stopping: "Stopping Capture…"
        case .failed(let error): error.title
        }
    }

    @objc private func toggleCapture() { actions.toggleCapture() }
    @objc private func showControls() { actions.showControls() }
    @objc private func toggleIsland() { actions.toggleIsland() }
    @objc private func openPrivacySettings() { actions.openPrivacySettings() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func clearTranscript() { actions.clearTranscript() }
    @objc private func summarizeTranscript() { actions.summarize() }
    @objc private func selectAskOnce() { actions.setAskMode(.once) }
    @objc private func selectChat() { actions.setAskMode(.chat) }
    @objc private func startNewChat() { actions.newChat() }
    @objc private func askAssistant() { actions.ask() }
    @objc private func openSetupGuide() { actions.openSetupGuide() }
}
