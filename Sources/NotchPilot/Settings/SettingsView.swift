import NotchPilotCore
import SwiftUI

/// Settings › Assistant: provider, API key, model and system prompt. Standard grouped Form
/// controls in the system appearance; nothing in Settings is island-styled.
struct AssistantSettingsPane: View {
    @Bindable var store: AssistantSettingsStore
    @State private var keyDrafts: [AIProvider: String] = [:]
    @State private var confirmingRemoval: AIProvider?

    private var provider: AIProvider { store.settings.provider }
    private let defaults = AssistantSettings()

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $store.settings.provider) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text("Ask sends your request to this service.")
                    .foregroundStyle(.secondary)
            }

            Section {
                apiKeyRow
                TextField("Model", text: modelBinding, prompt: Text(defaultModel))
                if provider == .claude {
                    Picker("Effort", selection: $store.settings.claudeEffort) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                }
            } header: {
                Text(provider.displayName)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if provider == .claude {
                        Text("Higher effort can give more thorough replies but takes longer.")
                            .foregroundStyle(.secondary)
                    }
                    Link("Get a \(provider.displayName) API key", destination: keyPageURL)
                }
            }

            Section {
                TextEditor(text: $store.settings.systemPrompt)
                    .font(.body)
                    .frame(height: 96)
                    .accessibilityLabel("System prompt")
                HStack {
                    Spacer()
                    Button("Restore Default") { store.settings.systemPrompt = defaults.systemPrompt }
                        .disabled(store.settings.systemPrompt == defaults.systemPrompt)
                }
            } header: {
                Text("System Prompt")
            } footer: {
                privacyNote
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsPane.width, height: 560)
        .confirmationDialog(removalTitle, isPresented: removalBinding, presenting: confirmingRemoval) { provider in
            Button("Remove Key", role: .destructive) { store.removeKey(for: provider) }
            Button("Cancel", role: .cancel) {}
        } message: { provider in
            Text("You’ll need to paste the key again to ask \(provider.displayName).")
        }
        .onAppear(perform: store.refreshSavedKeys)
    }

    // MARK: API key

    /// The key is never shown back: once saved, the row only says so.
    @ViewBuilder private var apiKeyRow: some View {
        if store.savedKeys.contains(provider) {
            LabeledContent("API Key") {
                HStack(spacing: 8) {
                    Label("Saved in Keychain", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Button("Remove…") { confirmingRemoval = provider }
                }
            }
        } else {
            LabeledContent("API Key") {
                HStack(spacing: 8) {
                    SecureField("API Key", text: draftBinding, prompt: Text(keyPlaceholder))
                        .labelsHidden()
                        .onSubmit(saveDraft)
                    Button("Save", action: saveDraft)
                        .disabled(draftBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        if let error = store.keyError {
            ErrorLabel(error.message)
                .help(error.technicalDetail ?? "")
        }
    }

    private func saveDraft() {
        if store.saveKey(draftBinding.wrappedValue, for: provider) { keyDrafts[provider] = nil }
    }

    private var draftBinding: Binding<String> {
        let provider = provider
        return Binding(get: { keyDrafts[provider] ?? "" }, set: { keyDrafts[provider] = $0 })
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } })
    }

    private var removalTitle: String {
        "Remove the \(confirmingRemoval?.displayName ?? "") API key from the Keychain?"
    }

    private var keyPlaceholder: String {
        provider == .claude ? "sk-ant-…" : "sk-…"
    }

    private var keyPageURL: URL {
        switch provider {
        case .claude: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    // MARK: Model

    private var defaultModel: String {
        provider == .claude ? defaults.claudeModel : defaults.openAIModel
    }

    private var modelBinding: Binding<String> {
        switch provider {
        case .claude: $store.settings.claudeModel
        case .openAI: $store.settings.openAIModel
        }
    }

    // MARK: Privacy

    /// States exactly what leaves the Mac and when (HIG › Privacy: "Be transparent about how
    /// your app collects and uses people’s data").
    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("What NotchPilot sends", systemImage: "lock.fill")
                .font(.callout.weight(.semibold))
            Text("""
                Speech is transcribed on this Mac; audio never leaves it. Nothing is sent until \
                you press Ask. Then NotchPilot sends one request to \(provider.displayName) with \
                the most recent transcript (up to \(store.settings.transcriptCharacterLimit.formatted()) \
                characters), your question, the system prompt and, only if Include Screen is on, \
                one screenshot of your main display.
                """)
            Text("API keys are stored in your Keychain. Transcripts, screenshots and replies stay in memory and are never saved to disk.")
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Inline error in Settings: only the symbol is red; the text keeps the primary label
/// colour, because red text on the grouped background is below 4.5:1
/// (HIG › Accessibility; HIG › Color: don't rely on colour alone).
struct ErrorLabel: View {
    let message: String
    var textStyle: HierarchicalShapeStyle = .primary

    init(_ message: String, textStyle: HierarchicalShapeStyle = .primary) {
        self.message = message
        self.textStyle = textStyle
    }

    var body: some View {
        Label {
            Text(message).foregroundStyle(textStyle)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
