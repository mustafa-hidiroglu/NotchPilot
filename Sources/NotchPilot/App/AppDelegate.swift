import AppKit
import NotchPilotCore

/// Wires the capture service, island and status item together on the main actor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = NotchPilotConfig.default
    private var service: AudioCaptureService?
    private var model: IslandViewModel?
    private var panelController: IslandPanelController?
    private var statusItem: StatusItemController?
    private var observers: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let service = AudioCaptureService(config: config)
        let model = IslandViewModel(config: config, service: service)
        let panelController = IslandPanelController(model: model, config: config)

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
            isIslandVisible: { [weak panelController] in panelController?.isVisible ?? false },
            captureState: { [weak model] in model?.captureState ?? .idle }))

        // Bridge capture events to the UI. Both streams are bounded (newest wins) and are
        // fed from non-real-time code only.
        observers.append(Task { [weak model, weak statusItem] in
            for await state in service.states {
                model?.captureState = state
                statusItem?.update(for: state)
            }
        })
        observers.append(Task { [weak model] in
            for await snapshot in service.levels {
                model?.level = snapshot
            }
        })

        self.service = service
        self.model = model
        self.panelController = panelController
        self.statusItem = statusItem
        panelController.show()   // capture stays off until the person starts it
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
        observers.forEach { $0.cancel() }
        panelController?.invalidate()
    }
}
