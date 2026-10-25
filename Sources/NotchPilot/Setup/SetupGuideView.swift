import NotchPilotCore
import SwiftUI

/// The setup guide's content: three numbered steps that each turn into a checkmark when
/// done; the shortcut tip, the optional login item and Done sit in the footer, always in
/// view. Standard grouped Form controls in the system appearance, like Settings; semantic
/// colours only, so light, dark and Increase Contrast come from the system. Status is never
/// carried by colour alone: the badge changes shape (number → checkmark / exclamation mark)
/// and the row says "Done".
struct SetupGuideView: View {
    static let width: CGFloat = 540
    /// Header, three steps and footer without scrolling on a 13-inch MacBook Air with the
    /// Dock showing (visible height about 806 pt, window title bar included).
    static let idealHeight: CGFloat = 720

    let model: SetupGuideModel
    let done: () -> Void
    @State private var keyDrafts: [AIProvider: String] = [:]
    @FocusState private var keyFieldFocused: Bool

    private var snapshot: SetupSnapshot { model.snapshot }

    /// Only the first unfinished step's button is prominent, so one action leads at a time.
    private func isNext(_ step: SetupStep) -> Bool { SetupChecklist.nextStep(in: snapshot) == step }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                screenRecordingStep
                speechModelStep
                apiKeyStep
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(minWidth: Self.width, idealWidth: Self.width, minHeight: 420, idealHeight: Self.idealHeight)
        .onExitCommand(perform: done)
        .onChange(of: model.store.settings.provider) { old, _ in
            // A key typed for one provider never lingers after switching to the other.
            keyDrafts[old] = nil
            model.cancelKeyCheck()
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set Up NotchPilot")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Three steps. Skip any and come back later from the menu bar.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 0)
    }

    /// Always visible: the shortcut tip, the login checkbox, progress and Done.
    private var footer: some View {
        let settings = model.store.settings
        let tip = SetupChecklist.shortcutTip(shortcut: model.shortcutDisplay,
                                             singlePress: settings.askHotKeySinglePress,
                                             doublePress: settings.askHotKeyDoublePress)
        let count = SetupChecklist.completedCount(in: snapshot)
        return VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(tip).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "keyboard")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spokenTip(settings: settings))
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    LoginItemToggle(loginItem: model.loginItem, asCheckbox: true)
                }
                Spacer(minLength: 8)
                Text(count == SetupStep.allCases.count ? "All set." : "\(count) of \(SetupStep.allCases.count) done")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                // Return presses Done, except while typing a key (Return saves the key there).
                Button("Done", action: done)
                    .keyboardShortcut(keyFieldFocused ? nil : .defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    /// The tip with the shortcut spelled out for VoiceOver ("Shift Command Space").
    private func spokenTip(settings: AssistantSettings) -> String {
        let spoken = model.shortcutDisplay == nil ? nil : settings.askHotKey.localizedSpoken
        return SetupChecklist.shortcutTip(shortcut: spoken, singlePress: settings.askHotKeySinglePress,
                                          doublePress: settings.askHotKeyDoublePress)
    }

    // MARK: Step 1 — Screen & System Audio Recording

    private var screenRecordingStep: some View {
        let status = SetupChecklist.status(of: .screenRecording, in: snapshot)
        return Section {
            SetupStepRow(number: 1, title: "Screen & System Audio Recording", status: status) {
                Text("Lets NotchPilot turn the sound your Mac plays (a call, a video) into text. Never the microphone, and nothing is recorded. After you allow it, macOS may ask to quit and reopen NotchPilot. That’s expected.")
            } actions: {
                switch SetupChecklist.screenRecordingAction(in: snapshot) {
                case .requestAccess:
                    // Not "Allow": the system prompt holds the real choice
                    // (HIG › Privacy › Pre-alert screens).
                    Button("Request Access…", action: model.requestScreenCapture)
                        .emphasized(isNext(.screenRecording))
                case .openPrivacySettings:
                    Button("Open Privacy Settings", action: model.openPrivacySettings)
                        .emphasized(isNext(.screenRecording))
                case .none:
                    EmptyView()
                }
            }
        }
    }

    // MARK: Step 2 — Speech model

    private var speechModelStep: some View {
        let speechModel = model.speechModel
        let status = SetupChecklist.status(of: .speechModel, in: snapshot)
        let size = SpeechSettingsPane.size(speechModel)
        let modelNote = speechModel.id == SpeechModel.recommendedID
            ? "\(speechModel.displayName) model, recommended for this Mac"
            : "\(speechModel.displayName) model, chosen in Settings › Speech"
        return Section {
            SetupStepRow(number: 2, title: "Speech Model", status: status) {
                Text("Turns speech into text on this Mac; speech never leaves it. Downloaded once from huggingface.co.")
            } actions: {
                switch status {
                case .toDo:
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Download Speech Model (\(size))", action: model.downloadSpeechModel)
                            .emphasized(isNext(.speechModel))
                            .fixedSize()
                            .accessibilityHint(modelNote)
                        Text(modelNote)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                case .needsAttention:
                    Button("Try Again", action: model.downloadSpeechModel)
                        .accessibilityLabel("Try downloading the speech model again")
                case .inProgress(let fraction):
                    HStack(spacing: 8) {
                        ProgressView(value: fraction)
                            .frame(width: 160)
                            .accessibilityLabel("Downloading the speech model")
                            .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                            .accessibilityHidden(true)
                        Button("Cancel", action: model.cancelSpeechModelDownload)
                            .accessibilityLabel("Cancel downloading the speech model")
                    }
                case .done:
                    EmptyView()
                }
                if let error = model.speechModels.errors[speechModel.id] {
                    ErrorLabel(error)
                }
            }
        }
    }

    // MARK: Step 3 — AI provider key

    private var apiKeyStep: some View {
        let store = model.store
        let provider = store.settings.provider
        let status = SetupChecklist.status(of: .apiKey, in: snapshot)
        return Section {
            SetupStepRow(number: 3, title: "AI Provider Key", status: status) {
                Text("Nothing is sent until you press Ask or Summarize. Ask sends the recent transcript, your question, earlier turns in a chat, and a screenshot only when Include Screen is on. Summarize sends the transcript only.")
            } actions: {
                Picker("Provider", selection: Bindable(store).settings.provider) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                if store.savedKeys.contains(provider) {
                    savedKeyRow(provider: provider)
                } else {
                    HStack(spacing: 8) {
                        SecureField("\(provider.displayName) API key", text: draftBinding(for: provider),
                                    prompt: Text(provider == .claude ? "Paste your key (sk-ant-…)" : "Paste your key (sk-…)"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .focused($keyFieldFocused)
                            .onSubmit { saveDraft(for: provider) }
                            .accessibilityLabel("\(provider.displayName) API key")
                        Button("Save Key") { saveDraft(for: provider) }
                            .disabled(draftBinding(for: provider).wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    keyHowTo(provider: provider)
                }
                if let error = store.keyError {
                    ErrorLabel(error.message)
                        .help(error.technicalDetail ?? "")
                }
            }
        }
    }

    /// Saved: say so, and offer Check Key, the only request the guide ever sends, and only
    /// when pressed.
    @ViewBuilder private func savedKeyRow(provider: AIProvider) -> some View {
        HStack(spacing: 10) {
            Label("Key saved in your Keychain", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            switch model.keyCheck {
            case .checking:
                ProgressView().controlSize(.small).accessibilityLabel("Checking key")
            case .works:
                Label("Key works", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.secondary)
            case .idle, .failed:
                EmptyView()
            }
            Button("Check Key", action: model.checkKey)
                .disabled(model.keyCheck == .checking)
                .help("Sends one tiny test request to \(provider.displayName). Nothing else is sent.")
        }
        if case .failed(let error) = model.keyCheck {
            ErrorLabel(error.message)
                .help(error.technicalDetail ?? "")
        }
    }

    /// The real hurdle for someone new to API keys: where to get one and what it costs.
    private func keyHowTo(provider: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Link("Get a \(provider.displayName) API key", destination: keyPageURL(for: provider))
            Text("1. Sign in or create an account  2. Add billing (pay per use, usually cents a day)  3. Create a key and paste it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func draftBinding(for provider: AIProvider) -> Binding<String> {
        Binding(get: { keyDrafts[provider] ?? "" }, set: { keyDrafts[provider] = $0 })
    }

    /// Same path as Settings › Assistant: the store trims the key and writes it straight to
    /// the Keychain; the draft is dropped as soon as it is saved. After a failed save the
    /// draft is kept so Save Key can be retried without pasting again (Keychain failures are
    /// usually a declined access prompt); it still goes when the provider changes or the
    /// window closes, which tears the view down.
    private func saveDraft(for provider: AIProvider) {
        if model.store.saveKey(keyDrafts[provider] ?? "", for: provider) {
            keyDrafts[provider] = nil
            keyFieldFocused = false
            model.cancelKeyCheck()
        }
    }

    private func keyPageURL(for provider: AIProvider) -> URL {
        switch provider {
        case .claude: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        }
    }
}

/// One numbered step: badge, title and status on the first line, the explanation below,
/// then the step's controls. VoiceOver reads it as one container titled
/// "Step 1 of 3, Screen & System Audio Recording, Done".
private struct SetupStepRow<Detail: View, Actions: View>: View {
    let number: Int
    let title: String
    let status: SetupStepStatus
    @ViewBuilder let detail: Detail
    @ViewBuilder let actions: Actions

    init(number: Int, title: String, status: SetupStepStatus,
         @ViewBuilder detail: () -> Detail, @ViewBuilder actions: () -> Actions) {
        self.number = number
        self.title = title
        self.status = status
        self.detail = detail()
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StepBadge(number: number, status: status)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer(minLength: 8)
                    if status.isDone {
                        Text("Done").foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    detail
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if case .needsAttention(let message) = status {
                    ErrorLabel(message)
                }
                // Once a step is done its controls step aside, except the provider choice,
                // which stays changeable.
                actions
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number) of \(SetupStep.allCases.count), \(title), \(spokenStatus)")
    }

    private var spokenStatus: String {
        switch status {
        case .toDo: "to do"
        case .inProgress(let fraction): "downloading, \(fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .needsAttention: "needs attention"
        case .done: "done"
        }
    }
}

/// Number in a ring while to do, a filled checkmark when done, an exclamation mark when it
/// needs attention. Shape carries the state; colour only reinforces it.
private struct StepBadge: View {
    let number: Int
    let status: SetupStepStatus

    var body: some View {
        Group {
            switch status {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
            case .needsAttention:
                Image(systemName: "exclamationmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .orange)
            case .toDo, .inProgress:
                Image(systemName: "\(number).circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 22))
        .frame(width: 26, height: 26)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityHidden(true)
    }
}

private extension View {
    @ViewBuilder func emphasized(_ emphasized: Bool) -> some View {
        if emphasized { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
}
