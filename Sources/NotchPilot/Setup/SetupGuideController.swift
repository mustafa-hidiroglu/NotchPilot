import AppKit
import CoreGraphics
import NotchPilotCore
import Observation
import SwiftUI

/// Owns the first-run setup guide: a small standard window (not the island) with three
/// steps and live status. Shown once on first launch and reopenable from the status menu
/// (HIG › Onboarding: "If you let people skip the tutorial when they first launch your app,
/// don’t present it again on subsequent launches, but make sure it’s easy for people to
/// find if they want to view it later").
///
/// Closing the window counts as finishing for now, exactly like Done: closing is how people
/// skip it, and a guide that reappears on every launch until each step is finished would
/// nag. Every step it covers is also reachable from Settings and the island.
@MainActor
final class SetupGuideController: NSObject, NSWindowDelegate {
    private let store: AssistantSettingsStore
    private let speechModels: SpeechModelsController
    private let hotKeys: HotKeyCenter
    private let loginItem: LoginItemController
    private let replyService: ReplyService
    private let openPrivacySettings: () -> Void
    private var window: NSWindow?
    private var model: SetupGuideModel?
    private var ticker: Task<Void, Never>?

    init(store: AssistantSettingsStore, speechModels: SpeechModelsController, hotKeys: HotKeyCenter,
         loginItem: LoginItemController, replyService: ReplyService, openPrivacySettings: @escaping () -> Void) {
        self.store = store
        self.speechModels = speechModels
        self.hotKeys = hotKeys
        self.loginItem = loginItem
        self.replyService = replyService
        self.openPrivacySettings = openPrivacySettings
    }

    /// First launch only.
    func showIfNeeded() {
        guard !store.settings.hasCompletedSetup else { return }
        show()
    }

    func show() {
        let window = window ?? makeWindow()
        model?.refresh()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        // No field starts focused, so Return presses Done and VoiceOver starts at the top
        // instead of inside the key field.
        window.makeFirstResponder(nil)
        NSApp.activate()
        startTicker()
    }

    func invalidate() {
        ticker?.cancel()
        ticker = nil
        model?.cancelKeyCheck()
    }

    private func makeWindow() -> NSWindow {
        let model = SetupGuideModel(store: store, speechModels: speechModels, hotKeys: hotKeys, loginItem: loginItem,
                                    replyService: replyService, openPrivacySettings: openPrivacySettings)
        // Reads the Keychain once per opening, off the main actor (keys only change through
        // the shared store afterwards, which updates `savedKeys` itself).
        Task { [store] in await store.refreshSavedKeysInBackground() }
        let view = SetupGuideView(model: model, done: { [weak self] in self?.window?.performClose(nil) })
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: controller)
        window.title = "NotchPilot Setup"
        window.styleMask = [.titled, .closable, .resizable]
        window.contentMinSize = NSSize(width: SetupGuideView.width, height: 420)
        // The content is sized to fit in about 720 pt, so the window opens without scrolling
        // on a 13-inch MacBook Air with the Dock showing (visible height about 806 pt); on a
        // shorter screen it is capped to the screen and the steps scroll.
        let available = (NSScreen.main?.visibleFrame.height ?? SetupGuideView.idealHeight) - 60
        window.setContentSize(NSSize(width: SetupGuideView.width, height: min(SetupGuideView.idealHeight, max(420, available))))
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.delegate = self
        self.window = window
        self.model = model
        return window
    }

    /// Light polling while the window is open: the permission has no change notification,
    /// and macOS grants it in System Settings, outside the app. Every 2 seconds, never a
    /// busy loop; cancelled when the window closes.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                // Ends once the controller is gone; holds it only for one refresh.
                guard let self, !Task.isCancelled else { return }
                self.model?.refresh()
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        model?.refresh()
    }

    /// Called for the close button, Done and Esc (all go through `performClose`), but not
    /// when the window goes away because NotchPilot quits: quitting before looking at the
    /// guide shouldn't count as having seen it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        store.settings.hasCompletedSetup = true
        store.persistNow()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        invalidate()
        let closing = window
        // Leave no half-typed key in memory: the view is rebuilt next time.
        window?.contentViewController = nil
        window = nil
        model = nil
        // Hand focus back to the app the person was using, unless Settings is still open.
        let otherWindowOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
        if !otherWindowOpen { NSApp.deactivate() }
    }
}

/// Live facts for the guide. The permission and the shortcut's registration have no change
/// notification, so they are re-read by `refresh()`; the model download and saved keys are
/// observed directly from the shared controllers.
@MainActor
@Observable
final class SetupGuideModel {
    private static let requestedKey = "SetupRequestedScreenCapture"

    /// Result of the last "Check Key", for the provider it was run for.
    enum KeyCheck: Equatable {
        case idle
        case checking
        case works
        case failed(AssistantError)
    }

    let store: AssistantSettingsStore
    let speechModels: SpeechModelsController
    let loginItem: LoginItemController
    @ObservationIgnored private let hotKeys: HotKeyCenter
    @ObservationIgnored private let replyService: ReplyService
    @ObservationIgnored private let openPrivacySettingsAction: () -> Void
    @ObservationIgnored private var keyCheckTask: Task<Void, Never>?
    private(set) var keyCheck = KeyCheck.idle

    private(set) var hasScreenCapturePermission = AudioCaptureService.hasCapturePermission
    private(set) var didRequestScreenCapture = UserDefaults.standard.bool(forKey: SetupGuideModel.requestedKey)
    private(set) var isHotKeyActive = false

    init(store: AssistantSettingsStore, speechModels: SpeechModelsController, hotKeys: HotKeyCenter,
         loginItem: LoginItemController, replyService: ReplyService, openPrivacySettings: @escaping () -> Void) {
        self.store = store
        self.speechModels = speechModels
        self.hotKeys = hotKeys
        self.loginItem = loginItem
        self.replyService = replyService
        self.openPrivacySettingsAction = openPrivacySettings
        isHotKeyActive = hotKeys.isActive
    }

    func refresh() {
        let permission = AudioCaptureService.hasCapturePermission
        if permission != hasScreenCapturePermission { hasScreenCapturePermission = permission }
        if hotKeys.isActive != isHotKeyActive { isHotKeyActive = hotKeys.isActive }
        loginItem.refresh()
    }

    var speechModel: SpeechModel {
        SpeechModel.named(store.settings.speechModelID) ?? SpeechModel.named(SpeechModel.recommendedID)!
    }

    var snapshot: SetupSnapshot {
        SetupSnapshot(hasScreenCapturePermission: hasScreenCapturePermission,
                      didRequestScreenCapture: didRequestScreenCapture,
                      speechModelState: speechModels.state(of: speechModel),
                      hasAPIKey: store.savedKeys.contains(store.settings.provider))
    }

    /// The displayed shortcut, or nil when it is off or couldn't be registered.
    var shortcutDisplay: String? {
        guard store.settings.askHotKeyEnabled, isHotKeyActive else { return nil }
        return store.settings.askHotKey.localizedDisplay
    }

    // MARK: Actions

    /// Shows the system prompt. macOS shows it only once per app; after that the call just
    /// returns false, so the step switches to opening System Settings. The guide never
    /// tries to grant or bypass the permission itself.
    func requestScreenCapture() {
        let granted = CGRequestScreenCaptureAccess()
        UserDefaults.standard.set(true, forKey: Self.requestedKey)
        didRequestScreenCapture = true
        if granted { hasScreenCapturePermission = true }
    }

    func openPrivacySettings() {
        openPrivacySettingsAction()
    }

    /// "Check Key": one minimal request, only on this button (see `APIKeyCheck`).
    func checkKey() {
        keyCheckTask?.cancel()
        keyCheck = .checking
        let service = replyService
        let settings = store.effectiveSettings
        keyCheckTask = Task { [weak self] in
            do {
                try await APIKeyCheck.run(with: service, settings: settings)
                guard !Task.isCancelled else { return }
                self?.keyCheck = .works
            } catch is CancellationError {
            } catch let error as AssistantError {
                guard !Task.isCancelled else { return }
                self?.keyCheck = .failed(error)
            } catch {
                guard !Task.isCancelled else { return }
                self?.keyCheck = .failed(.network(error.localizedDescription))
            }
        }
    }

    /// A different provider or a new key makes the last result meaningless.
    func cancelKeyCheck() {
        keyCheckTask?.cancel()
        keyCheckTask = nil
        keyCheck = .idle
    }

    func downloadSpeechModel() { speechModels.download(speechModel) }
    func cancelSpeechModelDownload() { speechModels.cancelDownload(speechModel) }
}
