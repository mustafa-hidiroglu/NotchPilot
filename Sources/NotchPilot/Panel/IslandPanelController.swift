import AppKit
import NotchPilotCore
import SwiftUI

/// Owns the panel: positioning on the primary display, resizing around presentation changes,
/// display-change handling and click-outside dismissal.
///
/// Resizing strategy: the panel is sized to the *larger* of the current and target island
/// sizes for the duration of a transition (grow before expanding, shrink after collapsing
/// finishes), and SwiftUI animates the island inside it. The window itself never animates,
/// so there is no frame jumping, and in the resting compact state the panel covers only the
/// island, never blocking clicks on the rest of the menu bar or desktop.
@MainActor
final class IslandPanelController: IslandPanelHosting {
    private let panel: NotchPanel
    private let model: IslandViewModel
    private let config: NotchPilotConfig
    private var screenObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?

    init(model: IslandViewModel, config: NotchPilotConfig) {
        self.model = model
        self.config = config
        panel = NotchPanel(features: config.features)

        let hosting = NSHostingView(rootView: IslandView(model: model))
        hosting.sizingOptions = []           // the controller, not SwiftUI, decides the window size
        panel.contentView = hosting
        panel.onCancel = { [weak model] in model?.setPresentation(.compact) }

        model.panelHost = self
        refreshGeometry()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGeometry() }
        }
    }

    func invalidate() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        removeOutsideClickMonitor()
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the panel without activating the app or taking key status.
    func show() {
        refreshGeometry()
        panel.orderFrontRegardless()
    }

    func hide() {
        model.setPresentation(.compact, animated: false)
        panel.orderOut(nil)
    }

    // MARK: IslandPanelHosting

    func presentationWillChange(to presentation: IslandPresentation) {
        // Grow first so the expanding island is never clipped by the window.
        if presentation == .expanded {
            setPanelFrame(for: .expanded)
            installOutsideClickMonitor()
        } else {
            removeOutsideClickMonitor()
            relinquishKeyStatus()
        }
    }

    /// A key non-activating panel keeps receiving keystrokes after it collapses. Re-ordering
    /// the panel without making it key lets the window server return key status to the
    /// active app's window.
    private func relinquishKeyStatus() {
        guard panel.isKeyWindow, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    func presentationDidSettle(at presentation: IslandPresentation) {
        // Shrink only once the collapse animation has finished.
        if presentation == .compact { setPanelFrame(for: .compact) }
    }

    /// Makes the panel key for keyboard use (only on explicit user request). Because the
    /// panel is non-activating, the frontmost app stays active.
    func focusForKeyboard() {
        guard panel.isVisible else { return }
        panel.makeKey()
    }

    // MARK: Geometry

    private func refreshGeometry() {
        guard let screen = NSScreen.screens.first else { return }   // primary display (has the menu bar)
        model.geometry = IslandGeometry(config: config.layout, display: Self.metrics(for: screen),
                                        attachToNotch: config.features.attachToNotch)
        // Mid-transition, keep the larger frame so a running collapse isn't clipped;
        // presentationDidSettle shrinks it afterwards.
        setPanelFrame(for: model.hasPendingTransition ? .expanded : model.presentation)
    }

    private func setPanelFrame(for presentation: IslandPresentation) {
        let frame = model.geometry.panelFrame(for: presentation)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true, animate: false)
    }

    static func metrics(for screen: NSScreen) -> DisplayMetrics {
        var notchWidth: CGFloat = 0
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, screen.frame.width - left.width - right.width)
        }
        return DisplayMetrics(frame: screen.frame, visibleFrame: screen.visibleFrame,
                              notchHeight: screen.safeAreaInsets.top, notchWidth: notchWidth)
    }

    // MARK: Click-outside dismissal

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        // Global monitors only observe clicks delivered to *other* apps/windows; they cannot
        // modify or consume events and need no extra permission for mouse events.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.setPresentation(.compact) }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
}
