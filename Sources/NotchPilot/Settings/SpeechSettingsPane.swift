import NotchPilotCore
import SwiftUI

/// Settings › Speech: which whisper model transcribes, in which language, and the model
/// downloads. Choosing and managing are separate: the pop-up picks the model in use, the
/// list below downloads or deletes each one with determinate progress (HIG › Progress
/// indicators: "When possible, use a determinate progress indicator").
struct SpeechSettingsPane: View {
    @Bindable var store: AssistantSettingsStore
    let models: SpeechModelsController
    @State private var confirmingDelete: SpeechModel?

    private var selected: SpeechModel {
        SpeechModel.named(store.settings.speechModelID) ?? SpeechModel.named(SpeechModel.recommendedID)!
    }

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $store.settings.speechModelID) {
                    ForEach(SpeechModel.catalog) { model in
                        Text(Self.pickerLabel(model)).tag(model.id)
                    }
                }
                Picker("Language", selection: $store.settings.speechLanguage) {
                    Text("Automatic").tag("auto")
                    Divider()
                    ForEach(languageOptions, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
            } footer: {
                if models.state(of: selected) != .installed {
                    Text("Download \(selected.displayName) below to start transcribing.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Automatic detects the spoken language. Choosing it can be more accurate for short phrases.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(SpeechModel.catalog) { model in
                    SpeechModelRow(model: model,
                                   state: models.state(of: model),
                                   error: models.errors[model.id],
                                   inUse: model.id == selected.id,
                                   download: { models.download(model) },
                                   cancel: { models.cancelDownload(model) },
                                   delete: { confirmingDelete = model })
                }
            } header: {
                Text("Models")
            } footer: {
                Label("Speech is transcribed on this Mac. Downloading a model fetches it once from huggingface.co.",
                      systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsPane.width, height: 540)
        // Deleting means downloading hundreds of MB again, so it is confirmed
        // (HIG › Alerts: confirm destructive actions; Cancel is always offered).
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, presenting: confirmingDelete) { model in
            Button("Delete", role: .destructive) { models.delete(model) }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            if model.id == selected.id {
                Text("NotchPilot can’t transcribe until you download it again or choose another model.")
            } else {
                Text("You can download it again at any time (\(Self.size(model))).")
            }
        }
    }

    private var deleteTitle: String {
        "Delete the \(confirmingDelete?.displayName ?? "") speech model?"
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })
    }

    /// Every model stays selectable; one that is best with more memory than this Mac has
    /// says so up front (HIG › Generative AI: set clear expectations about limitations).
    static func pickerLabel(_ model: SpeechModel) -> String {
        var label = model.displayName
        if model.id == SpeechModel.recommendedID { label += " (Recommended)" }
        if !model.fitsThisMac, let memory = model.recommendedMemoryGB { label += " — best with \(memory) GB memory" }
        return label
    }

    static func size(_ model: SpeechModel) -> String {
        ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)
    }

    // MARK: Languages

    /// Whisper language codes for widely spoken languages, named in the person's language
    /// and sorted by that name. A stored code outside the list is kept and shown too.
    private var languageOptions: [(code: String, name: String)] {
        var codes = Self.languageCodes
        let current = store.settings.speechLanguage
        if current != "auto", !codes.contains(current) { codes.append(current) }
        return codes
            .map { (code: $0, name: Locale.current.localizedString(forLanguageCode: $0)?.localizedCapitalized ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static let languageCodes = [
        "ar", "bg", "ca", "cs", "da", "de", "el", "en", "es", "fa", "fi", "fr", "he", "hi", "hr", "hu",
        "id", "it", "ja", "ko", "ms", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sv", "th", "tr", "uk",
        "ur", "vi", "zh",
    ]
}

/// One catalog model: name, size and summary on the leading side, its install action on
/// the trailing side.
private struct SpeechModelRow: View {
    let model: SpeechModel
    let state: SpeechModelInstallState
    let error: String?
    let inUse: Bool
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    var body: some View {
        LabeledContent {
            action
        } label: {
            HStack(spacing: 6) {
                Text(model.displayName)
                if model.id == SpeechModel.recommendedID {
                    Text("Recommended for this Mac")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
            }
            Text("\(SpeechSettingsPane.size(model)) · \(model.summary)")
            if let message = failureMessage {
                ErrorLabel(message)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var downloadButton: some View {
        Button("Download", action: download)
            .accessibilityLabel("Download \(model.displayName), \(SpeechSettingsPane.size(model))")
    }

    private var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return error
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .notInstalled:
            // The model in use but missing is the one thing to do on this pane.
            if inUse {
                downloadButton.buttonStyle(.borderedProminent)
            } else {
                downloadButton
            }
        case .failed:
            Button("Try Again", action: download)
                .accessibilityLabel("Try downloading \(model.displayName) again")
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: min(max(fraction, 0), 1))
                    .frame(width: 80)
                    .accessibilityLabel("Downloading \(model.displayName)")
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
                    .accessibilityHidden(true)
                Button("Cancel", action: cancel)
                    .accessibilityLabel("Cancel downloading \(model.displayName)")
            }
        case .installed:
            HStack(spacing: 8) {
                Label(inUse ? "In Use" : "Downloaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                // Ellipsis: asks for confirmation first (HIG › Menus).
                Button("Delete…", action: delete)
                    .accessibilityLabel("Delete \(model.displayName)")
            }
        }
    }
}
