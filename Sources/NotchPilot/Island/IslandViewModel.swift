import AppKit
import NotchPilotCore
import Observation
import SwiftUI

/// What the island needs from the window layer around a presentation change.
@MainActor
protocol IslandPanelHosting: AnyObject {
    func presentationWillChange(to presentation: IslandPresentation)
    func presentationDidSettle(at presentation: IslandPresentation)
    /// Only for explicit user interaction (click or menu), never for background updates.
    func focusForKeyboard()
}

/// Main-actor presentation state for the island. Receives capture state and level
/// snapshots from `AudioCaptureService` streams; never touched by audio threads.
@MainActor
@Observable
final class IslandViewModel {
    let config: NotchPilotConfig
    private(set) var presentation: IslandPresentation = .compact
    var geometry: IslandGeometry
    var captureState: CaptureState = .idle {
        didSet {
            // VoiceOver hears failures even while the island is collapsed.
            if case .failed(let error) = captureState, captureState != oldValue {
                AccessibilityNotification.Announcement("NotchPilot: \(error.title)").post()
            }
        }
    }
    var level = LevelSnapshot()
    /// Mirrors the SwiftUI environment (set by IslandView) so animation choice and view
    /// transitions always agree.
    @ObservationIgnored var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    @ObservationIgnored weak var panelHost: IslandPanelHosting?
    @ObservationIgnored private let service: AudioCaptureService
    @ObservationIgnored private var transitionID = 0
    @ObservationIgnored private var settledTransitionID = 0

    /// True while an open/close animation is still running.
    var hasPendingTransition: Bool { transitionID != settledTransitionID }

    init(config: NotchPilotConfig, service: AudioCaptureService) {
        self.config = config
        self.service = service
        geometry = IslandGeometry(
            config: config.layout,
            display: DisplayMetrics(frame: .zero, visibleFrame: .zero, notchHeight: 0, notchWidth: 0),
            attachToNotch: false)
    }

    var format: PCMFormat { service.outputFormat }

    // MARK: Intents

    /// Click on the island header. Does not take key status, so keystrokes keep going to the
    /// frontmost app; keyboard use goes through the menu's "Show Controls".
    func toggleExpanded() {
        setPresentation(presentation == .compact ? .expanded : .compact)
    }

    /// Changes presentation with the configured spring, or a short cross-fade when Reduce
    /// Motion is on. Interruptible: a new request retargets the running animation, and only
    /// the latest transition's completion resizes the panel.
    func setPresentation(_ target: IslandPresentation, animated: Bool = true) {
        guard target != presentation else { return }
        transitionID += 1
        let id = transitionID
        panelHost?.presentationWillChange(to: target)

        guard animated else {
            presentation = target
            settledTransitionID = id
            panelHost?.presentationDidSettle(at: target)
            return
        }
        withAnimation(transitionAnimation(to: target), completionCriteria: .removed) {
            presentation = target
        } completion: { [weak self] in
            guard let self, self.transitionID == id else { return }
            self.settledTransitionID = id
            self.panelHost?.presentationDidSettle(at: target)
        }
    }

    func toggleCapture() {
        let service = service
        if captureState.isActive {
            Task { await service.stop() }
        } else {
            Task { await service.start() }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Motion

    private func transitionAnimation(to target: IslandPresentation) -> Animation {
        let motion = config.animation
        if reduceMotion { return .easeInOut(duration: motion.reducedMotionFade) }
        return target == .expanded
            ? .spring(response: motion.expandResponse, dampingFraction: motion.expandDamping)
            : .spring(response: motion.collapseResponse, dampingFraction: motion.collapseDamping)
    }
}
