import AppKit
import NotchPilotCore
import Observation
import SwiftUI

/// What the island needs from the window layer around a presentation change.
@MainActor
protocol IslandPanelHosting: AnyObject {
    func presentationWillChange(to presentation: IslandPresentation)
    func presentationDidSettle(at presentation: IslandPresentation)
    /// The expanded island's extra height for assistant output is changing (grow) or has
    /// finished changing (shrink); `panelAccessoryHeight` holds the height to size for.
    func accessoryHeightDidChange()
    /// Only for explicit user interaction (click or menu), never for background updates.
    func focusForKeyboard()
}

/// Progress of one Ask, shown below the Ask row.
enum AskPhase: Equatable {
    case idle
    case capturingScreen
    case waiting(AIProvider)
    case replied(AssistantReply)
    case failed(AskFailure)

    var isBusy: Bool {
        switch self {
        case .capturingScreen, .waiting: true
        case .idle, .replied, .failed: false
        }
    }
}

/// A user-facing Ask failure: a title-style headline, a plain message, raw detail for a
/// tooltip only, and an optional fix.
struct AskFailure: Equatable {
    enum Fix: Equatable {
        case openSettings
        case openScreenPrivacySettings
    }

    var title: String
    var message: String
    var technicalDetail: String?
    var fix: Fix?

    init(_ error: AssistantError) {
        title = error.title
        message = error.message
        technicalDetail = error.technicalDetail
        switch error {
        case .missingAPIKey, .invalidAPIKey, .requestRejected, .keychain: fix = .openSettings
        default: fix = nil
        }
    }

    init(_ error: ScreenshotError) {
        switch error {
        case .permissionDenied:
            title = "Screen Access Needed"
            message = "Allow NotchPilot in Screen & System Audio Recording, or turn off Include Screen."
            technicalDetail = nil
            fix = .openScreenPrivacySettings
        case .noDisplay:
            title = "No Display Found"
            message = "NotchPilot couldn’t find a display to capture. Turn off Include Screen and ask again."
            technicalDetail = nil
            fix = nil
        case .captureFailed(let detail):
            title = "Screen Not Captured"
            message = "NotchPilot couldn’t capture the screen. Try again, or turn off Include Screen."
            technicalDetail = detail
            fix = nil
        case .encodingFailed:
            title = "Screen Not Captured"
            message = "NotchPilot couldn’t prepare the screenshot. Try again, or turn off Include Screen."
            technicalDetail = nil
            fix = nil
        }
    }
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

    // Assistant
    var transcriptionState: TranscriptionState = .off
    var transcript = Transcript()
    var question = ""
    var includeScreen: Bool
    private(set) var askPhase: AskPhase = .idle {
        didSet { updateAccessoryHeight() }
    }
    /// Extra expanded height currently laid out for assistant output (animated).
    private(set) var accessoryHeight: CGFloat = 0
    /// Height the panel must accommodate: the larger of the current and target heights
    /// while a change animates, so growing content is never clipped by the window.
    @ObservationIgnored private(set) var panelAccessoryHeight: CGFloat = 0
    let settingsStore: AssistantSettingsStore
    /// Opens the Settings window (set by the app delegate).
    @ObservationIgnored var openSettings: () -> Void = {}
    /// Mirrors the SwiftUI environment (set by IslandView) so animation choice and view
    /// transitions always agree.
    @ObservationIgnored var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    @ObservationIgnored weak var panelHost: IslandPanelHosting?
    @ObservationIgnored private let service: AudioCaptureService
    @ObservationIgnored private let transcriber: SystemAudioTranscriber
    @ObservationIgnored private let replyService: ReplyService
    @ObservationIgnored private let screenshotter: any ScreenshotCapturing
    @ObservationIgnored private var askTask: Task<Void, Never>?
    @ObservationIgnored private var transitionID = 0
    @ObservationIgnored private var settledTransitionID = 0
    @ObservationIgnored private var accessoryTransitionID = 0

    /// True while an open/close animation is still running.
    var hasPendingTransition: Bool { transitionID != settledTransitionID }

    init(config: NotchPilotConfig, service: AudioCaptureService, transcriber: SystemAudioTranscriber,
         replyService: ReplyService, screenshotter: any ScreenshotCapturing, settingsStore: AssistantSettingsStore) {
        self.config = config
        self.service = service
        self.transcriber = transcriber
        self.replyService = replyService
        self.screenshotter = screenshotter
        self.settingsStore = settingsStore
        includeScreen = settingsStore.settings.includeScreenshotByDefault
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
            // Starting capture is the person's request to transcribe, so this is when the
            // Speech Recognition prompt may appear (HIG › Privacy: request permission only
            // when the feature needs it). It returns at once when already decided.
            Task {
                _ = await SystemAudioTranscriber.requestAuthorization()
                await service.start()
            }
        }
    }

    /// Follows capture: transcription runs exactly while capture is running.
    func captureStateDidChange(to state: CaptureState) {
        captureState = state
        switch state {
        case .running: transcriber.start()
        case .idle, .failed: transcriber.stop()
        case .starting, .stopping: break
        }
    }

    /// "Continue" next to "Speech recognition needs permission": shows the system prompt.
    func requestSpeechPermission() {
        let transcriber = transcriber
        Task { @MainActor [weak self] in
            _ = await SystemAudioTranscriber.requestAuthorization()
            if case .running = self?.captureState { transcriber.start() }
        }
    }

    func openSpeechPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    func clearTranscript() {
        transcript = Transcript()
        transcriber.clear()
    }

    // MARK: Ask

    var provider: AIProvider { settingsStore.settings.provider }

    /// Sends one request: optional on-demand screenshot, then the provider call. This is the
    /// only path that touches the network.
    func ask() {
        guard !askPhase.isBusy else { return }
        let settings = settingsStore.effectiveSettings
        let recent = transcript.recentText(limit: settings.transcriptCharacterLimit)
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        // Checked before capturing, so no screenshot is taken for a request that can't be sent.
        guard !recent.isEmpty || !trimmedQuestion.isEmpty else {
            askPhase = .failed(AskFailure(.nothingToSend))
            return
        }
        let wantsScreen = includeScreen
        let screenshotter = screenshotter
        let replyService = replyService

        askTask = Task { [weak self] in
            do {
                var screenshot: Data?
                if wantsScreen {
                    self?.askPhase = .capturingScreen
                    // Keep "Capturing Screen…" up long enough to be noticed.
                    async let minimumVisible: Void = try Task.sleep(for: .milliseconds(600))
                    screenshot = try await screenshotter.captureMainDisplayJPEG(maxLongEdge: 1568, quality: 0.7)
                    try await minimumVisible
                }
                try Task.checkCancellation()
                self?.askPhase = .waiting(settings.provider)
                let request = ReplyRequest(transcript: recent,
                                           question: trimmedQuestion.isEmpty ? nil : trimmedQuestion,
                                           screenshotJPEG: screenshot,
                                           systemPrompt: settings.systemPrompt)
                let reply = try await replyService.reply(to: request, settings: settings)
                try Task.checkCancellation()
                self?.finishAsk(.replied(reply))
            } catch is CancellationError {
                self?.askPhase = .idle
            } catch let error as AssistantError {
                self?.finishAsk(.failed(AskFailure(error)))
            } catch let error as ScreenshotError {
                self?.finishAsk(.failed(AskFailure(error)))
            } catch {
                self?.finishAsk(.failed(AskFailure(.network(error.localizedDescription))))
            }
        }
    }

    func cancelAsk() {
        askTask?.cancel()
        askTask = nil
        askPhase = .idle
    }

    func dismissReply() {
        guard !askPhase.isBusy else { return }
        askPhase = .idle
    }

    func copyReply() {
        guard case .replied(let reply) = askPhase else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reply.text, forType: .string)
    }

    func performFix(_ fix: AskFailure.Fix) {
        switch fix {
        case .openSettings: openSettings()
        case .openScreenPrivacySettings: openPrivacySettings()
        }
    }

    /// Click into the question field: the panel becomes key (without activating the app) so
    /// the field receives typing.
    func beginTyping() {
        panelHost?.focusForKeyboard()
    }

    private func finishAsk(_ phase: AskPhase) {
        askTask = nil
        askPhase = phase
        // VoiceOver hears the outcome even while the island is collapsed.
        let announcement = switch phase {
        case .replied(let reply): "\(reply.provider.displayName) replied"
        case .failed(let failure): failure.title
        default: ""
        }
        if !announcement.isEmpty { AccessibilityNotification.Announcement(announcement).post() }
    }

    private func updateAccessoryHeight() {
        let layout = config.layout
        let target: CGFloat = switch askPhase {
        case .idle: 0
        case .capturingScreen, .waiting, .failed: layout.expandedNoticeHeight
        case .replied: layout.expandedReplyHeight
        }
        guard target != accessoryHeight else { return }
        accessoryTransitionID += 1
        let id = accessoryTransitionID
        // Reduce Motion: the island changes height in one step, with no growth animation
        // (HIG › Motion: make motion optional).
        if reduceMotion {
            panelAccessoryHeight = target
            panelHost?.accessoryHeightDidChange()
            accessoryHeight = target
            return
        }
        // Grow the window first; shrink it only after the island has finished shrinking.
        panelAccessoryHeight = max(panelAccessoryHeight, target)
        panelHost?.accessoryHeightDidChange()
        let motion = config.animation
        withAnimation(.spring(response: motion.collapseResponse, dampingFraction: motion.collapseDamping),
                      completionCriteria: .removed) {
            accessoryHeight = target
        } completion: { [weak self] in
            guard let self, self.accessoryTransitionID == id else { return }
            self.panelAccessoryHeight = target
            self.panelHost?.accessoryHeightDidChange()
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
