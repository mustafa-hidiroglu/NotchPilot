import AppKit
import NotchPilotCore

/// Wires the capture service, transcriber, assistant, island, settings window and status item
/// together on the main actor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = NotchPilotConfig.default
    private var service: AudioCaptureService?
    /// Strong reference: the capture service holds its processor weakly.
    private var transcriber: WhisperTranscriber?
    /// Whisper model downloads; Settings › Speech shows and drives it.
    private(set) var speechModels: SpeechModelStore?
    private var settingsWindow: SettingsWindowController?
    /// First-run setup guide (lane-setup).
    private var setupGuide: SetupGuideController?
    private var settingsStore: AssistantSettingsStore?
    private var model: IslandViewModel?
    private var panelController: IslandPanelController?
    private var statusItem: StatusItemController?
    private var hotKeys: HotKeyCenter?
    private var speechModelsController: SpeechModelsController?
    private var observers: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let speechModels = SpeechModelStore()
        let transcriber = WhisperTranscriber(modelStore: speechModels)
        let service = AudioCaptureService(config: config, processor: transcriber)
        let keyStore = KeychainAPIKeyStore()
        let settingsStore = AssistantSettingsStore(keyStore: keyStore)
        let model = IslandViewModel(config: config, service: service, transcriber: transcriber,
                                    replyService: ReplyService(keyStore: keyStore),
                                    screenshotter: ScreenshotCapturer(), settingsStore: settingsStore)
        let panelController = IslandPanelController(model: model, config: config)
        let hotKeys = HotKeyCenter()
        let speechModelsController = SpeechModelsController(store: speechModels)
        model.speechModels = speechModelsController
        // Deleting the in-use model stops transcription with it: restarting finds no file,
        // reports .needsModel and frees the loaded model.
        speechModelsController.onModelUninstalled = { [weak model, weak settingsStore] id in
            if id == settingsStore?.settings.speechModelID { model?.speechSettingsDidChange() }
        }
        let loginItem = LoginItemController()   // one instance for Settings › General and the setup guide
        let settingsWindow = SettingsWindowController(store: settingsStore, speechModels: speechModelsController, hotKeys: hotKeys,
                                                      loginItem: loginItem)
        self.settingsStore = settingsStore
        model.openSettings = { [weak settingsWindow] pane in settingsWindow?.show(pane: pane) }
        let setupGuide = SetupGuideController(store: settingsStore, speechModels: speechModelsController, hotKeys: hotKeys,
                                              loginItem: loginItem, replyService: ReplyService(keyStore: keyStore),
                                              openPrivacySettings: { [weak model] in model?.openPrivacySettings() })

        // Global Ask shortcut: open the island ready to type; press again to close.
        // One press opens the chosen mode, a quick second press switches to the other one,
        // a later press closes (IslandPanelController.handleAskHotKey).
        hotKeys.onPress = { [weak panelController] in panelController?.handleAskHotKey() }
        hotKeys.update(enabled: settingsStore.settings.askHotKeyEnabled, hotKey: settingsStore.settings.askHotKey)

        settingsStore.onChange = { [weak model, weak hotKeys] old, new in
            // The island's Include Screen follows the default when the default changes.
            if old.includeScreenshotByDefault != new.includeScreenshotByDefault {
                model?.includeScreen = new.includeScreenshotByDefault
            }
            if old.speechModelID != new.speechModelID || old.speechLanguage != new.speechLanguage {
                model?.speechSettingsDidChange()
            }
            if old.askHotKeyEnabled != new.askHotKeyEnabled || old.askHotKey != new.askHotKey {
                hotKeys?.update(enabled: new.askHotKeyEnabled, hotKey: new.askHotKey)
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
            ask: { [weak panelController] in panelController?.beginQuickAsk() },
            askTitle: { [weak model] in "Ask \(model?.provider.displayName ?? "")" },
            askShortcut: { [weak settingsStore, weak hotKeys] in
                guard let settings = settingsStore?.settings, settings.askHotKeyEnabled,
                      let hotKeys, hotKeys.isActive else { return nil }
                return settings.askHotKey
            },
            hasTranscript: { [weak model] in !(model?.transcript.fullText.isEmpty ?? true) },
            summarize: { [weak panelController] in panelController?.summarize() },
            canSummarize: { [weak model] in model?.canSummarize ?? false },
            providerName: { [weak model] in model?.provider.displayName ?? "" },
            askMode: { [weak model] in model?.askMode ?? .once },
            canChangeMode: { [weak model] in !(model?.askPhase.isBusy ?? true) },
            setAskMode: { [weak panelController] mode in panelController?.showMode(mode) },
            newChat: { [weak panelController] in panelController?.newChat() },
            canStartNewChat: { [weak model] in model?.canStartNewChat ?? false },
            isIslandVisible: { [weak panelController] in panelController?.isVisible ?? false },
            captureState: { [weak model] in model?.captureState ?? .idle },
            openSetupGuide: { [weak setupGuide] in setupGuide?.show() }))

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
        // A finished download of the selected model lets a running capture start transcribing.
        observers.append(Task { [weak model, weak settingsStore] in
            var wasInstalled: Bool?
            for await snapshot in speechModels.installStates {
                guard let selected = settingsStore?.settings.speechModelID else { continue }
                let installed = snapshot[selected] == .installed
                if installed, wasInstalled == false { model?.speechSettingsDidChange() }
                wasInstalled = installed
            }
        })
        observers.append(Task { [weak model] in
            for await snapshot in service.levels {
                model?.level = snapshot
            }
        })

        self.service = service
        self.transcriber = transcriber
        self.speechModels = speechModels
        self.settingsWindow = settingsWindow
        self.setupGuide = setupGuide
        self.model = model
        self.panelController = panelController
        self.statusItem = statusItem
        self.hotKeys = hotKeys
        self.speechModelsController = speechModelsController
        MainMenu.install(settingsTarget: self, settingsAction: #selector(showSettings))
        panelController.show()   // capture stays off until the person starts it
        setupGuide.showIfNeeded()   // first launch only (hasCompletedSetup == false)
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
        transcriber?.shutdown()   // the whisper model must be freed before exit (see shutdown())
        hotKeys?.invalidate()
        speechModelsController?.invalidate()
        setupGuide?.invalidate()
        panelController?.invalidate()
    }
}
