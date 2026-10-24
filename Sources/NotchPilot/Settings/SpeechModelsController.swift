import Foundation
import NotchPilotCore
import Observation

/// Main-actor front for `SpeechModelManaging`, shared by Settings › Speech and the island's
/// first-run download. Owned by the app delegate, so a download keeps running (and stays
/// cancellable) whichever of them started it.
@MainActor
@Observable
final class SpeechModelsController {
    private(set) var states: [SpeechModel.ID: SpeechModelInstallState] = [:]
    /// Failures the install states don't carry (a delete that failed, or a download error
    /// the store didn't publish), keyed by model.
    private(set) var errors: [SpeechModel.ID: String] = [:]

    /// A model stopped being installed (deleted, or its file went missing). The app restarts
    /// transcription so a deleted in-use model isn't kept in memory.
    @ObservationIgnored var onModelUninstalled: (SpeechModel.ID) -> Void = { _ in }
    @ObservationIgnored private let store: any SpeechModelManaging
    /// Running downloads. The token tells a finishing task whether its entry is still the
    /// current one, so a cancelled task can't clear a newer download's entry.
    @ObservationIgnored private var downloads: [SpeechModel.ID: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var observer: Task<Void, Never>?

    init(store: any SpeechModelManaging) {
        self.store = store
        observer = Task { [weak self] in
            for await snapshot in store.installStates {
                self?.apply(snapshot)
            }
        }
    }

    func invalidate() {
        observer?.cancel()
        downloads.values.forEach { $0.task.cancel() }
    }

    func state(of model: SpeechModel) -> SpeechModelInstallState {
        states[model.id] ?? (store.installedFileURL(for: model) != nil ? .installed : .notInstalled)
    }

    func download(_ model: SpeechModel) {
        guard downloads[model.id] == nil else { return }
        errors[model.id] = nil
        let store = store
        let token = UUID()
        let task = Task { [weak self] in
            do {
                try await store.download(model)
            } catch where !Task.isCancelled && !(error is CancellationError) {
                // The store reports failures as `.failed`; cover one it didn't. Cancel is
                // not a failure.
                if let self, !self.state(of: model).isFailed {
                    self.errors[model.id] = "The download didn’t finish. Check your internet connection and try again."
                }
            } catch {}
            if self?.downloads[model.id]?.token == token { self?.downloads[model.id] = nil }
        }
        downloads[model.id] = (token, task)
    }

    /// Clears the entry at once, so Download works again immediately after Cancel.
    func cancelDownload(_ model: SpeechModel) {
        downloads[model.id]?.task.cancel()
        downloads[model.id] = nil
    }

    func delete(_ model: SpeechModel) {
        cancelDownload(model)
        do {
            try store.delete(model)
            errors[model.id] = nil
        } catch {
            errors[model.id] = "NotchPilot couldn’t delete this model. Try again."
        }
    }

    private func apply(_ snapshot: [SpeechModel.ID: SpeechModelInstallState]) {
        let previous = states
        states = snapshot
        for (id, state) in previous where state == .installed && snapshot[id] != .installed {
            onModelUninstalled(id)
        }
    }
}

private extension SpeechModelInstallState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
