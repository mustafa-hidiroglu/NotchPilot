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
    /// The request is sent; nothing has come back yet.
    case waiting(AIProvider)
    /// Reply text is arriving; `reply.text` grows (coalesced) until the stream finishes.
    case streaming(AssistantReply)
    /// The complete reply, or the part that arrived before the person pressed Stop.
    case replied(AssistantReply, stoppedEarly: Bool)
    case failed(AskFailure)

    var isBusy: Bool {
        switch self {
        case .capturingScreen, .waiting, .streaming: true
        case .idle, .replied, .failed: false
        }
    }

    /// Phases that show reply text and use the tall output area.
    var showsReply: Bool {
        switch self {
        case .streaming, .replied: true
        case .idle, .capturingScreen, .waiting, .failed: false
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
    /// Ask Once (one question, one reply) or Chat (follow-ups keep the conversation).
    private(set) var askMode: AskMode {
        didSet { updateAccessoryHeight() }
    }
    /// The conversation shown in Chat mode (turns, per-turn details, the pending draft); in
    /// memory until New Chat or quit.
    private(set) var chat = ChatThread()
    /// New Chat just cleared a conversation; the island offers Undo for a few seconds.
    private(set) var showsChatClearedNotice = false
    /// What the current or latest Ask was for (progress and a one-time reply say "Summary").
    private(set) var askPurpose: AskPurpose = .answer
    /// A chat reply finished while the island was collapsed.
    private(set) var hasUnseenChatReply = false
    /// Extra expanded height currently laid out for assistant output (animated).
    private(set) var accessoryHeight: CGFloat = 0
    /// Height the panel must accommodate: the larger of the current and target heights
    /// while a change animates, so growing content is never clipped by the window.
    @ObservationIgnored private(set) var panelAccessoryHeight: CGFloat = 0
    let settingsStore: AssistantSettingsStore
    /// Speech model downloads, shared with Settings › Speech so the island can offer the
    /// first download in place (set by the app delegate).
    @ObservationIgnored var speechModels: SpeechModelsController?
    /// Opens the Settings window at a pane, or the last one viewed (set by the app delegate).
    @ObservationIgnored var openSettings: (SettingsPane?) -> Void = { _ in }
    /// Set when the question field should take keyboard focus (global Ask shortcut);
    /// the island view clears it once the field has focus.
    var wantsQuestionFocus = false
    /// Mirrors the SwiftUI environment (set by IslandView) so animation choice and view
    /// transitions always agree.
    @ObservationIgnored var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    @ObservationIgnored weak var panelHost: IslandPanelHosting?
    @ObservationIgnored private let service: AudioCaptureService
    @ObservationIgnored private let transcriber: any SystemAudioTranscribing
    @ObservationIgnored private let replyService: ReplyService
    @ObservationIgnored private let screenshotter: any ScreenshotCapturing
    @ObservationIgnored private var askTask: Task<Void, Never>?
    @ObservationIgnored private var currentAskID: UUID?
    /// Mode the running Ask was sent in (switching modes is disabled while one runs).
    @ObservationIgnored private var currentAskMode: AskMode = .once
    /// The question and screenshot choice of the latest one-time Ask, so switching to Chat
    /// can continue from its reply.
    @ObservationIgnored private var lastOnceQuestion: String?
    @ObservationIgnored private var lastOnceIncludedScreen = false
    /// The conversation New Chat replaced, until Undo or the next question.
    @ObservationIgnored private var clearedChat: ChatThread?
    @ObservationIgnored private var clearedNoticeTask: Task<Void, Never>?
    /// The panel's undo manager (set by the panel controller), for Undo New Chat (⌘Z).
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Text of the reply being streamed, and the pending coalesced UI update.
    @ObservationIgnored private var replyBuffer = ReplyTextCoalescer()
    @ObservationIgnored private var replyFlushTask: Task<Void, Never>?
    @ObservationIgnored private var transitionID = 0
    @ObservationIgnored private var settledTransitionID = 0
    @ObservationIgnored private var accessoryTransitionID = 0

    /// True while an open/close animation is still running.
    var hasPendingTransition: Bool { transitionID != settledTransitionID }

    init(config: NotchPilotConfig, service: AudioCaptureService, transcriber: any SystemAudioTranscribing,
         replyService: ReplyService, screenshotter: any ScreenshotCapturing, settingsStore: AssistantSettingsStore) {
        self.config = config
        self.service = service
        self.transcriber = transcriber
        self.replyService = replyService
        self.screenshotter = screenshotter
        self.settingsStore = settingsStore
        includeScreen = settingsStore.settings.includeScreenshotByDefault
        askMode = settingsStore.settings.askHotKeySinglePress
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
        if target == .expanded { hasUnseenChatReply = false }
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

    /// Follows capture: transcription runs exactly while capture is running.
    func captureStateDidChange(to state: CaptureState) {
        captureState = state
        switch state {
        case .running: startTranscriber()
        case .idle, .failed: transcriber.stop()
        case .starting, .stopping: break
        }
    }

    /// Settings › Speech changed the model or language (or the model finished downloading):
    /// restart transcription with them if capture is running.
    func speechSettingsDidChange() {
        if case .running = captureState { startTranscriber() }
    }

    /// The whisper model chosen in Settings › Speech.
    var selectedSpeechModel: SpeechModel {
        SpeechModel.named(settingsStore.settings.speechModelID) ?? SpeechModel.named(SpeechModel.recommendedID)!
    }

    private func startTranscriber() {
        transcriber.start(model: selectedSpeechModel, language: settingsStore.settings.speechLanguage)
    }

    func clearTranscript() {
        transcript = Transcript()
        transcriber.clear()
    }

    // MARK: Ask

    var provider: AIProvider { settingsStore.settings.provider }

    /// A reply is waiting while the island is collapsed; the compact island shows a badge
    /// until the reply is seen or dismissed.
    var hasReplyWhileCollapsed: Bool {
        guard presentation == .compact else { return false }
        if hasUnseenChatReply { return true }
        guard askMode == .once, case .replied = askPhase else { return false }
        return true
    }

    /// The island's Summarize button: capture has stopped and the transcript has enough
    /// text. Never automatic; nothing is sent until the button is pressed.
    var offersSummary: Bool {
        SummaryEligibility.offersSummary(for: transcript, isCapturing: captureState.isActive)
    }

    /// The status menu's Summarize Transcript item.
    var canSummarize: Bool {
        !askPhase.isBusy && !transcript.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sends the question (or, with none, asks for a response to the transcript).
    func ask() {
        send(purpose: .answer)
    }

    /// Asks for key points, decisions and action items from the transcript. In Chat mode the
    /// summary becomes a turn of the conversation.
    func summarize() {
        send(purpose: .summary)
    }

    /// Switches between Ask Once and Chat (segmented control, ⌘1/⌘2, the status menu, or a
    /// quick second press of the Ask shortcut). Not while an Ask is running: returns false
    /// so the caller can give feedback. A one-time reply that is showing carries over into an
    /// empty chat, so it can be followed up; a failure notice is cleared.
    @discardableResult
    func setAskMode(_ mode: AskMode) -> Bool {
        guard mode != askMode else { return true }
        guard !askPhase.isBusy else { return false }
        var nextPhase = askPhase
        if case .failed = askPhase { nextPhase = .idle }
        if mode == .chat, case .replied(let reply, let stoppedEarly) = askPhase,
           chat.carryOver(question: lastOnceQuestion, purpose: askPurpose, includedScreen: lastOnceIncludedScreen,
                          reply: reply, stoppedEarly: stoppedEarly) {
            nextPhase = .idle
        }
        // A one-time reply that didn't carry over stays for when Ask Once is shown again.
        withAnimation(modeAnimation) {
            askPhase = nextPhase
            askMode = mode
        }
        return true
    }

    /// New Chat can't interrupt a reply in progress (Stop it first).
    var canStartNewChat: Bool { !chat.isEmpty && !askPhase.isBusy }

    /// Starts a new conversation. Undoable: ⌘Z (Edit › Undo New Chat) or the Undo button in
    /// the notice shown for a few seconds brings the old one back.
    func newChat() {
        guard canStartNewChat else { return }
        if case .failed = askPhase { askPhase = .idle }
        let previous = chat
        chat = ChatThread()
        hasUnseenChatReply = false
        clearedChat = previous
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.undoNewChat() }
        }
        undoManager?.setActionName("New Chat")
        showClearedNotice()
        AccessibilityNotification.Announcement("Chat cleared").post()
    }

    /// Brings back the conversation New Chat replaced.
    func undoNewChat() {
        guard let previous = clearedChat, !askPhase.isBusy else { return }
        // From the notice's Undo button the ⌘Z entry is now stale; from ⌘Z it is being used.
        if undoManager?.isUndoing == false { undoManager?.removeAllActions(withTarget: self) }
        clearedChat = nil
        hideClearedNotice()
        chat = previous
        AccessibilityNotification.Announcement("Chat restored").post()
    }

    private func showClearedNotice() {
        clearedNoticeTask?.cancel()
        showsChatClearedNotice = true
        clearedNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            self.showsChatClearedNotice = false
        }
    }

    private func hideClearedNotice() {
        clearedNoticeTask?.cancel()
        clearedNoticeTask = nil
        showsChatClearedNotice = false
    }

    /// The cleared chat can no longer come back once a new conversation has started.
    private func forgetClearedChat() {
        guard clearedChat != nil else { return }
        clearedChat = nil
        undoManager?.removeAllActions(withTarget: self)
        hideClearedNotice()
    }

    func copyChatTurn(_ turn: ChatTurn) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.text, forType: .string)
    }

    /// Sends one request: optional on-demand screenshot, then the provider call. This is the
    /// only path that touches the network.
    private func send(purpose: AskPurpose) {
        guard !askPhase.isBusy else { return }
        let settings = settingsStore.effectiveSettings
        let recent = transcript.recentText(limit: settings.transcriptCharacterLimit)
        // A summary ignores the question field (and leaves its text alone).
        let trimmedQuestion = purpose == .summary ? "" : question.trimmingCharacters(in: .whitespacesAndNewlines)
        // Checked before capturing, so no screenshot is taken for a request that can't be sent.
        guard !recent.isEmpty || !trimmedQuestion.isEmpty else {
            askPhase = .failed(AskFailure(.nothingToSend))
            return
        }
        // A summary never attaches a screenshot, whatever Include Screen says.
        let wantsScreen = purpose.sendsScreenshot && includeScreen
        let screenshotter = screenshotter
        let replyService = replyService
        let questionToSend = trimmedQuestion.isEmpty ? nil : trimmedQuestion

        // Chat: the history is the completed turns before this one; the new user turn is
        // pending until the reply completes. The field clears like a message composer and
        // gets its text (and Include Screen choice) back if the turn doesn't complete.
        var history: [ChatTurn] = []
        currentAskMode = askMode
        askPurpose = purpose
        if askMode == .chat {
            forgetClearedChat()
            let isSummary = purpose == .summary
            history = chat.send(question: questionToSend, purpose: purpose,
                                draft: ChatDraft(question: question, includeScreen: includeScreen),
                                includedScreen: wantsScreen)
            if !isSummary {
                question = ""
                // A screenshot goes only with the turn it was taken for; the next turn starts
                // from the default again, so a follow-up never sends the screen by accident.
                // (A summary uses no screenshot, so it leaves the toggle as it is.)
                includeScreen = settings.includeScreenshotByDefault
            }
        } else {
            lastOnceQuestion = questionToSend
            lastOnceIncludedScreen = wantsScreen
        }

        // Busy synchronously, before the task runs, so a second Ask (Return + click, or the
        // menu) can't slip past the guard. Each Ask gets an ID; only the current one may
        // change state, so a cancelled or superseded task can never clobber a newer Ask.
        askPhase = wantsScreen ? .capturingScreen : .waiting(settings.provider)
        let id = UUID()
        currentAskID = id
        resetReplyBuffer()
        let provider = settings.provider

        askTask = Task { [weak self] in
            do {
                var screenshot: Data?
                if wantsScreen {
                    // Keep "Capturing Screen…" up long enough to be noticed.
                    async let minimumVisible: Void = try Task.sleep(for: .milliseconds(600))
                    screenshot = try await screenshotter.captureMainDisplayJPEG(maxLongEdge: 1568, quality: 0.7)
                    try await minimumVisible
                }
                try Task.checkCancellation()
                self?.updateAsk(id, .waiting(settings.provider))
                let request = ReplyRequest(transcript: recent,
                                           question: questionToSend,
                                           screenshotJPEG: screenshot,
                                           systemPrompt: settings.systemPrompt,
                                           history: history,
                                           purpose: purpose)
                // Cancelling this task ends the stream, which cancels the network request.
                var model = ""
                for try await event in try replyService.streamReply(to: request, settings: settings) {
                    try Task.checkCancellation()
                    switch event {
                    case .started(let name):
                        model = name
                    case .textDelta(let delta):
                        self?.receive(delta, for: id, provider: provider, model: model)
                    case .finished(let truncated):
                        guard let self else { return }
                        let text = self.replyBuffer.text
                        guard !text.isEmpty || truncated else { throw AssistantError.invalidResponse(provider) }
                        let reply = AssistantReply(text: text, provider: provider, model: model, truncated: truncated)
                        self.finishAsk(id, .replied(reply, stoppedEarly: false))
                        return
                    }
                }
                throw AssistantError.invalidResponse(provider)
            } catch is CancellationError {
                // cancelAsk() already reset the state for this Ask.
            } catch let error as AssistantError {
                self?.finishAsk(id, .failed(AskFailure(error)))
            } catch let error as ScreenshotError {
                self?.finishAsk(id, .failed(AskFailure(error)))
            } catch {
                self?.finishAsk(id, .failed(AskFailure(.network(error.localizedDescription))))
            }
        }
    }

    func cancelAsk() {
        askTask?.cancel()
        askTask = nil
        currentAskID = nil
        resetReplyBuffer()
        if currentAskMode == .chat { restore(chat.abandon()) }
        askPhase = .idle
    }

    /// Stop while text is arriving keeps what has arrived (so it can be read and copied);
    /// before that it is the same as Cancel.
    func stopReply() {
        guard case .streaming(var reply) = askPhase else { return cancelAsk() }
        reply.text = replyBuffer.text
        askTask?.cancel()
        askTask = nil
        currentAskID = nil
        resetReplyBuffer()
        if currentAskMode == .chat {
            // The partial text becomes the turn (ChatSession keeps what the person saw); with
            // no text yet, the question goes back to the field.
            if case .dropped(let draft) = chat.complete(reply, stoppedEarly: true) { restore(draft) }
            askPhase = .idle
        } else {
            askPhase = .replied(reply, stoppedEarly: true)
        }
        AccessibilityNotification.Announcement("Reply stopped").post()
    }

    func dismissReply() {
        guard !askPhase.isBusy else { return }
        askPhase = .idle
    }

    func copyReply() {
        guard case .replied(let reply, _) = askPhase else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reply.text, forType: .string)
    }

    func performFix(_ fix: AskFailure.Fix) {
        switch fix {
        case .openSettings: openSettings(.assistant)
        case .openScreenPrivacySettings: openPrivacySettings()
        }
    }

    /// Click into the question field: the panel becomes key (without activating the app) so
    /// the field receives typing.
    func beginTyping() {
        panelHost?.focusForKeyboard()
    }

    /// Global Ask shortcut: the island is open and key; put the cursor in the question field.
    func requestQuestionFocus() {
        wantsQuestionFocus = true
    }

    /// Appends a streamed delta; the visible text is updated at most ~30 times a second
    /// (ReplyTextCoalescer), with a timer so trailing text shows even if the stream pauses.
    private func receive(_ delta: String, for id: UUID, provider: AIProvider, model: String) {
        guard currentAskID == id, !Task.isCancelled else { return }
        if let text = replyBuffer.append(delta, at: .now) {
            askPhase = .streaming(AssistantReply(text: text, provider: provider, model: model))
        } else if replyFlushTask == nil, let deadline = replyBuffer.pendingDeadline {
            replyFlushTask = Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard let self, !Task.isCancelled, self.currentAskID == id else { return }
                self.replyFlushTask = nil
                if let text = self.replyBuffer.flush(at: .now) {
                    self.askPhase = .streaming(AssistantReply(text: text, provider: provider, model: model))
                }
            }
        }
    }

    private func resetReplyBuffer() {
        replyFlushTask?.cancel()
        replyFlushTask = nil
        replyBuffer = ReplyTextCoalescer()
    }

    private func updateAsk(_ id: UUID, _ phase: AskPhase) {
        guard currentAskID == id, !Task.isCancelled else { return }
        askPhase = phase
    }

    private func finishAsk(_ id: UUID, _ phase: AskPhase) {
        guard currentAskID == id, !Task.isCancelled else { return }
        currentAskID = nil
        askTask = nil
        resetReplyBuffer()
        var outcome = phase
        if currentAskMode == .chat {
            switch phase {
            case .replied(let reply, let stoppedEarly):
                switch chat.complete(reply, stoppedEarly: stoppedEarly) {
                case .added:
                    if presentation == .compact { hasUnseenChatReply = true }
                    askPhase = .idle
                case .dropped(let draft):
                    // A reply with no text (even one cut off at the limit) isn't a turn: say
                    // so instead of announcing a reply that isn't there.
                    restore(draft)
                    outcome = .failed(AskFailure(.invalidResponse(reply.provider)))
                    askPhase = outcome
                }
            case .failed:
                // Refused or failed: no assistant turn, and the user turn goes too, so the
                // history stays alternating; the question returns to the field to retry.
                restore(chat.abandon())
                askPhase = phase
            default:
                askPhase = phase
            }
        } else {
            askPhase = phase
        }
        // VoiceOver hears the outcome once, when the reply is complete (never per delta),
        // even while the island is collapsed.
        let announcement = switch outcome {
        case .replied(let reply, _): "\(reply.provider.displayName) replied"
        case .failed(let failure): failure.title
        default: ""
        }
        if !announcement.isEmpty { AccessibilityNotification.Announcement(announcement).post() }
    }

    /// Gives a chat question's field text and Include Screen choice back.
    private func restore(_ draft: ChatDraft?) {
        draft?.restore(question: &question, includeScreen: &includeScreen)
    }

    private var modeAnimation: Animation {
        let motion = config.animation
        return reduceMotion ? .easeInOut(duration: motion.reducedMotionFade)
                            : .spring(response: motion.collapseResponse, dampingFraction: motion.collapseDamping)
    }

    private func updateAccessoryHeight() {
        let layout = config.layout
        let target: CGFloat = switch (askMode, askPhase) {
        // Chat keeps one height for the conversation, whatever its state.
        case (.chat, _): layout.expandedChatHeight
        case (.once, .idle): 0
        case (.once, .capturingScreen), (.once, .waiting), (.once, .failed): layout.expandedNoticeHeight
        // Full reply height from the first streamed delta, so the island grows once
        // rather than line by line.
        case (.once, .streaming), (.once, .replied): layout.expandedReplyHeight
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
