import Foundation
import NotchPilotCore
import Observation
import Security

/// Main-actor owner of the assistant preferences. Non-secret settings persist as JSON in
/// UserDefaults; API keys go straight to the Keychain through `APIKeyStoring` and are never
/// held here beyond the call that saves them.
@MainActor
@Observable
final class AssistantSettingsStore {
    private static let defaultsKey = "AssistantSettings"

    var settings: AssistantSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            onChange?(oldValue, settings)
        }
    }

    /// Providers that have a key in the Keychain. Only refreshed on request (opening
    /// Settings), so launching the app never touches the Keychain.
    private(set) var savedKeys: Set<AIProvider> = []
    /// Last Keychain failure, shown next to the key field.
    private(set) var keyError: AssistantError?

    @ObservationIgnored var onChange: ((_ old: AssistantSettings, _ new: AssistantSettings) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyStore: any APIKeyStoring

    init(defaults: UserDefaults = .standard, keyStore: any APIKeyStoring) {
        self.defaults = defaults
        self.keyStore = keyStore
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(AssistantSettings.self, from: data) {
            settings = stored
        } else {
            settings = AssistantSettings()
        }
    }

    /// Settings for a request: blank model names fall back to the defaults.
    var effectiveSettings: AssistantSettings {
        var result = settings
        let defaults = AssistantSettings()
        if result.claudeModel.trimmingCharacters(in: .whitespaces).isEmpty { result.claudeModel = defaults.claudeModel }
        if result.openAIModel.trimmingCharacters(in: .whitespaces).isEmpty { result.openAIModel = defaults.openAIModel }
        result.claudeModel = result.claudeModel.trimmingCharacters(in: .whitespaces)
        result.openAIModel = result.openAIModel.trimmingCharacters(in: .whitespaces)
        return result
    }

    // MARK: API keys

    func refreshSavedKeys() {
        var saved: Set<AIProvider> = []
        keyError = nil
        for provider in AIProvider.allCases {
            do {
                if let key = try keyStore.apiKey(for: provider), !key.isEmpty { saved.insert(provider) }
            } catch let error as AssistantError {
                keyError = error
            } catch {
                keyError = .keychain(errSecInternalError)
            }
        }
        savedKeys = saved
    }

    /// Returns true when the key was stored.
    @discardableResult
    func saveKey(_ key: String, for provider: AIProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard perform({ try keyStore.setAPIKey(trimmed, for: provider) }) else { return false }
        savedKeys.insert(provider)
        return true
    }

    func removeKey(for provider: AIProvider) {
        if perform({ try keyStore.removeAPIKey(for: provider) }) { savedKeys.remove(provider) }
    }

    private func perform(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            keyError = nil
            return true
        } catch let error as AssistantError {
            keyError = error
        } catch {
            keyError = .keychain(errSecInternalError)
        }
        return false
    }

    // MARK: Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
