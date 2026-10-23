import AppKit
import NotchPilotCore

/// Wires the capture service, transcriber, assistant, island, settings window and status item
/// together on the main actor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = NotchPilotConfig.default
    private var service: AudioCaptureService?
    /// Strong reference: the capture service holds its processor weakly.
    private var transcriber: SystemAudioTranscriber?
    private var settingsWindow: SettingsWindowController?
    private var settingsStore: AssistantSettingsStore?
    private var model: IslandViewModel?
    private var panelController: IslandPanelController?
    private var statusItem: StatusItemController?
    private var observers: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let transcriber = SystemAudioTranscriber(locale: .current)
        let service = AudioCaptureService(config: config, processor: transcriber)
        let keyStore = KeychainAPIKeyStore()
        let settingsStore = AssistantSettingsStore(keyStore: keyStore)
        let model = IslandViewModel(config: config, service: service, transcriber: transcriber,
                                    replyService: ReplyService(keyStore: keyStore),
                                    screenshotter: ScreenshotCapturer(), settingsStore: settingsStore)
        let panelController = IslandPanelController(model: model, config: config)
        let settingsWindow = SettingsWindowController(store: settingsStore)
        self.settingsStore = settingsStore
        model.openSettings = { [weak settingsWindow] in settingsWindow?.show() }
        // The island's Include Screen follows the default when the default changes.
        settingsStore.onChange = { [weak model] old, new in
            if old.includeScreenshotByDefault != new.includeScreenshotByDefault {
                model?.includeScreen = new.includeScreenshotByDefault
            }
        }

        let statusItem = StatusItemController(actions: .init(
            toggleIsland: { [weak panelController] in
                guard let panelController else { return }
                panelController.isVisible ? panelController.hide() : panelController.show()
            },
            showControls: { [weak panelController, weak model] in
                panelController?.show()
                model?.setPresentation(.expanded)
                panelController?.focusForKeyboard()
            },
            toggleCapture: { [weak model] in model?.toggleCapture() },
            openPrivacySettings: { [weak model] in model?.openPrivacySettings() },
            openSettings: { [weak settingsWindow] in settingsWindow?.show() },
            clearTranscript: { [weak model] in model?.clearTranscript() },
            ask: { [weak panelController, weak model] in
                // Shows the island so the progress and reply are visible.
                panelController?.show()
                model?.setPresentation(.expanded)
                model?.ask()
            },
            askTitle: { [weak model] in "Ask \(model?.provider.displayName ?? "")" },
            isAsking: { [weak model] in model?.askPhase.isBusy ?? false },
            hasTranscript: { [weak model] in !(model?.transcript.fullText.isEmpty ?? true) },
            isIslandVisible: { [weak panelController] in panelController?.isVisible ?? false },
            captureState: { [weak model] in model?.captureState ?? .idle }))

        // Bridge capture events to the UI. Both streams are bounded (newest wins) and are
        // fed from non-real-time code only.
        observers.append(Task { [weak model, weak statusItem] in
            for await state in service.states {
                model?.captureStateDidChange(to: state)
                statusItem?.update(for: state)
            }
        })
        observers.append(Task { [weak model] in
            for await state in transcriber.states {
                model?.transcriptionState = state
            }
        })
        observers.append(Task { [weak model] in
            for await transcript in transcriber.transcripts {
                model?.transcript = transcript
            }
        })
        observers.append(Task { [weak model] in
            for await snapshot in service.levels {
                model?.level = snapshot
            }
        })

        self.service = service
        self.transcriber = transcriber
        self.settingsWindow = settingsWindow
        self.model = model
        self.panelController = panelController
        self.statusItem = statusItem
        MainMenu.install(settingsTarget: self, settingsAction: #selector(showSettings))
        panelController.show()   // capture stays off until the person starts it
    }

    @objc private func showSettings() {
        settingsWindow?.show()
    }

    /// Stops capture before quitting so the stream is torn down in order. If
    /// ScreenCaptureKit never answers, quitting proceeds after a short timeout anyway.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Always stop (idempotent): the UI state can lag the actor, e.g. Start then Quit at once.
        guard let service else { return .terminateNow }
        // Two independent tasks (a task group would wait for the non-cancellable stop);
        // whichever finishes first replies, the other is ignored.
        Task {
            await service.stop()
            replyToTerminate()
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            replyToTerminate()
        }
        return .terminateLater
    }

    private var didReplyToTerminate = false

    private func replyToTerminate() {
        guard !didReplyToTerminate else { return }
        didReplyToTerminate = true
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        settingsStore?.persistNow()   // flush a pending debounced write
        observers.forEach { $0.cancel() }
        panelController?.invalidate()
    }
}
