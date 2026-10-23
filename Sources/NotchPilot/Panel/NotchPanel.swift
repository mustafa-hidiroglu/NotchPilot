import AppKit
import NotchPilotCore

/// Borderless, non-activating floating panel that hosts the island.
///
/// Window policy (see README › Window behaviour):
/// * `.nonactivatingPanel`: clicking the island never activates NotchPilot or pulls focus
///   from the frontmost app. The panel can still become key for keyboard use without
///   activating the app.
/// * Level `.statusBar` (above the menu bar, below menus and system alerts) so a
///   notch-attached island can overlap the menu bar strip around the camera housing.
/// * Collection behaviour: on every Space, stationary in Mission Control, skipped by
///   window cycling; optionally shown over full-screen apps.
/// * `sharingType = .none` asks the window server to exclude the panel from window sharing
///   and screen capture. This is a privacy measure, not a guarantee: behaviour differs by
///   macOS version and some capture tools ignore it.
final class NotchPanel: NSPanel {
    /// Escape / Cancel while the panel is key.
    var onCancel: (() -> Void)?

    init(features: NotchPilotConfig.Features) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if features.showOverFullScreenApps { behavior.insert(.fullScreenAuxiliary) }
        collectionBehavior = behavior

        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none          // SwiftUI animates the island; the window never animates

        // Transparent window: the island shape and its shadow are drawn by SwiftUI.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        if features.excludeFromScreenSharing { sharingType = .none }
        // The island is always dark; this makes system colours resolve to their dark variants.
        appearance = NSAppearance(named: .darkAqua)

        setAccessibilityRole(.popover)
        setAccessibilityLabel("NotchPilot")
    }

    // Allowed to become key (for Escape and Full Keyboard Access) but never main, and thanks
    // to `.nonactivatingPanel` becoming key does not activate the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
