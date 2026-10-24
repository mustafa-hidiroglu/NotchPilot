import NotchPilotCore
import SwiftUI

// Assistant rows of the expanded island: live transcript, Ask row and the output area
// (progress, error or reply). Same tokens as IslandView: black opaque surface, white text,
// black labels on light fills, yellow = needs attention, teal stays the level meter's.

/// Secondary capsule button for actions inside the output area (Copy, Cancel): light label
/// on a dark fill so it ranks below the light-filled primary actions. 24 pt tall
/// (HIG › Accessibility: macOS minimum control size is 20 × 20 pt).
/// The fill lightens on hover (HIG › Pointing devices: interactive elements give pointer
/// feedback) and again when pressed.
struct IslandSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverableLabel(configuration: configuration)
    }

    private struct HoverableLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        private var fillOpacity: Double {
            configuration.isPressed ? 0.24 : (isHovering && isEnabled ? 0.20 : 0.16)
        }

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IslandPalette.primary)
                .padding(.horizontal, 10)
                .frame(minWidth: 24, minHeight: 24)
                .background(Capsule().fill(Color.white.opacity(fillOpacity)))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
                .onHover { isHovering = $0 }
        }
    }
}

/// On/off chip: outlined when off, light-filled with a checkmark when on, so the state reads
/// from shape and symbol as well as fill. Keeps toggle semantics for VoiceOver.
struct IslandChipToggleStyle: ToggleStyle {
    var systemImage: String
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        return Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark" : systemImage)
                configuration.label
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isOn ? Color.black : IslandPalette.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(Capsule().fill(isOn ? IslandPalette.primary : Color.clear))
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : IslandPalette.controlBorder(highContrast: contrast == .increased), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

extension IslandPalette {
    /// Boundary of outlined controls: white 40% on black is 3.7:1 (non-text contrast ≥ 3:1).
    static func controlBorder(highContrast: Bool) -> Color { .white.opacity(highContrast ? 0.7 : 0.4) }
    /// Inset container that separates assistant output from the rest of the island
    /// (HIG › Live Activities: place a block of content in an inset container shape).
    static let container = Color.white.opacity(0.08)
}

// MARK: - Transcript

/// The last ~two lines of the live transcript, or why there is none.
struct TranscriptRow: View {
    let model: IslandViewModel
    @Environment(\.colorSchemeContrast) private var contrast

    static let height: CGFloat = 32

    private var secondary: Color {
        contrast == .increased ? IslandPalette.secondaryHighContrast : IslandPalette.secondary
    }

    var body: some View {
        Group {
            switch model.transcriptionState {
            case .listening:
                transcriptText(placeholder: "Listening for speech…")
            case .off:
                // First run: offer the download before capture is even started.
                if modelState == .installed {
                    transcriptText(placeholder: "A live transcript appears here while capturing.")
                } else {
                    modelDownloadRow
                }
            case .needsModel:
                if modelState == .installed {
                    preparing   // downloaded; transcription is about to restart with it
                } else {
                    modelDownloadRow
                }
            case .loadingModel:
                preparing
            case .unavailable(let reason):
                // A damaged or unusable model: Settings › Speech can re-download or switch it.
                notice(reason) { speechSettingsButton }
            case .failed(let reason):
                notice(reason) { EmptyView() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
    }

    /// Opens Settings directly at the Speech pane.
    private var speechSettingsButton: some View {
        Button("Open Settings") { model.openSettings(.speech) }
            .buttonStyle(IslandActionButtonStyle())
            .fixedSize()
            .accessibilityHint("Opens NotchPilot’s Speech settings, where you can download a speech model")
    }

    private var speechModel: SpeechModel { model.selectedSpeechModel }

    private var modelState: SpeechModelInstallState {
        model.speechModels?.state(of: speechModel) ?? .notInstalled
    }

    private var modelSize: String {
        ByteCountFormatter.string(fromByteCount: speechModel.sizeBytes, countStyle: .file)
    }

    /// The selected model isn't downloaded: the download is the primary action right here,
    /// with determinate progress and Cancel (HIG › Progress indicators); Settings is the
    /// secondary way to pick another model.
    @ViewBuilder private var modelDownloadRow: some View {
        switch modelState {
        case .downloading(let fraction):
            let clamped = min(max(fraction, 0), 1)
            HStack(spacing: 8) {
                Text("Downloading \(speechModel.displayName)…")
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                ProgressView(value: clamped)
                    .progressViewStyle(.linear)
                    .tint(IslandPalette.primary)
                    .accessibilityLabel("Downloading \(speechModel.displayName) speech model")
                Text(clamped.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(secondary)
                    .frame(minWidth: 34, alignment: .trailing)
                    .accessibilityHidden(true)
                Button("Cancel") { model.speechModels?.cancelDownload(speechModel) }
                    .buttonStyle(IslandSecondaryButtonStyle())
                    .accessibilityLabel("Cancel download")
            }
            .font(.system(size: 12, weight: .medium))
        case .failed(let message):
            notice(message) {
                downloadButton(title: "Try Again")
                secondarySettingsButton
            }
        case .notInstalled, .installed:
            notice(model.speechModels?.errors[speechModel.id] ?? "No speech model yet.") {
                downloadButton(title: "Download \(speechModel.displayName) (\(modelSize))")
                secondarySettingsButton
            }
        }
    }

    private func downloadButton(title: String) -> some View {
        Button(title) { model.speechModels?.download(speechModel) }
            .buttonStyle(IslandActionButtonStyle())
            .fixedSize()
            .accessibilityHint("Downloads the speech model once from huggingface.co. Speech is transcribed on this Mac.")
            .help("Downloads once from huggingface.co. Speech is transcribed on this Mac.")
    }

    private var secondarySettingsButton: some View {
        Button("Settings…") { model.openSettings(.speech) }
            .buttonStyle(IslandSecondaryButtonStyle())
            .fixedSize()
            .accessibilityLabel("Open Speech Settings")
            .accessibilityHint("Choose a different speech model")
    }

    /// The model is downloaded and loading into memory.
    private var preparing: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("Preparing \(speechModel.displayName) for transcription…")
                .foregroundStyle(secondary)
                .lineLimit(1)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }

    private func transcriptText(placeholder: String) -> some View {
        // Fixed character window, then head truncation, so the newest words stay visible.
        let text = model.transcript.recentText(limit: 180)
        return Text(text.isEmpty ? placeholder : text)
            .font(.system(size: 12))
            .foregroundStyle(secondary)
            .lineLimit(2)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityLabel("Live transcript")
            .accessibilityValue(text.isEmpty ? placeholder : text)
    }

    private func notice(_ message: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(IslandPalette.attention)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action()
        }
        .font(.system(size: 12, weight: .medium))
    }
}

// MARK: - Ask row

/// Optional question, Include Screen and the Ask button. Return in the field asks too.
struct AskRow: View {
    @Bindable var model: IslandViewModel
    var questionFocused: FocusState<Bool>.Binding
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 8) {
            TextField("Question", text: $model.question,
                      prompt: Text("Ask about what’s playing…").foregroundStyle(placeholder))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(IslandPalette.primary)
                .padding(.horizontal, 12)
                .frame(minWidth: 120, minHeight: 28, maxHeight: 28)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .overlay(Capsule().strokeBorder(fieldBorder, lineWidth: questionFocused.wrappedValue ? 1.5 : 1))
                .focused(questionFocused)
                // The panel is non-activating: clicking the field makes it key without
                // activating NotchPilot, so the frontmost app stays frontmost.
                .simultaneousGesture(TapGesture().onEnded {
                    model.beginTyping()
                    questionFocused.wrappedValue = true
                })
                .onSubmit(model.ask)
                .onExitCommand { model.setPresentation(.compact) }
                .accessibilityLabel("Question")
                .accessibilityHint("Optional. Press Return to ask \(model.provider.displayName).")

            Toggle("Include Screen", isOn: $model.includeScreen)
                .toggleStyle(IslandChipToggleStyle(systemImage: "display"))
                .help("Attach one screenshot of your main display to this request")
                .fixedSize()

            Button("Ask \(model.provider.displayName)", action: model.ask)
                .buttonStyle(IslandActionButtonStyle())
                .disabled(model.askPhase.isBusy)
                .help("Send the recent transcript\(model.includeScreen ? " and a screenshot" : "") to \(model.provider.displayName)")
                .fixedSize()
        }
    }

    /// Increase Contrast: same secondary step as the rest of the island.
    private var placeholder: Color {
        contrast == .increased ? IslandPalette.secondaryHighContrast : IslandPalette.secondary
    }

    private var fieldBorder: Color {
        questionFocused.wrappedValue ? IslandPalette.primary : IslandPalette.controlBorder(highContrast: contrast == .increased)
    }
}

// MARK: - Output

/// Progress, error or reply for the latest Ask, in an inset container whose height is
/// fixed per kind so the island grows once and text never re-wraps while it does.
struct AskOutput: View {
    let model: IslandViewModel
    let height: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var copied = false
    @State private var copiedReset: Task<Void, Never>?
    /// After Stop, keyboard focus moves from the vanished Stop button to Copy in the same
    /// spot, so Full Keyboard Access users don't lose their place (HIG › Focus and selection).
    @FocusState private var copyFocused: Bool

    private var secondary: Color {
        contrast == .increased ? IslandPalette.secondaryHighContrast : IslandPalette.secondary
    }

    var body: some View {
        Group {
            switch model.askPhase {
            case .idle:
                EmptyView()
            case .capturingScreen:
                progress("Capturing Screen…", detail: "One screenshot of your main display, kept in memory only.")
            case .waiting(let provider):
                // Specific about what happens next (HIG › Generative AI: "Consider giving
                // specific, reassuring feedback during generation").
                progress("Waiting for \(provider.displayName)…",
                         detail: "The reply appears here as \(provider.displayName) writes it.")
            case .failed(let failure):
                failureView(failure)
            case .streaming(let reply):
                replyView(reply, isStreaming: true, stoppedEarly: false)
            case .replied(let reply, let stoppedEarly):
                replyView(reply, isStreaming: false, stoppedEarly: stoppedEarly)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: model.config.layout.expandedCornerRadius - model.config.layout.contentInset,
                                     style: .continuous).fill(IslandPalette.container))
        .onDisappear { copiedReset?.cancel() }
        .onChange(of: model.askPhase) { _, phase in
            if case .replied(_, stoppedEarly: true) = phase { copyFocused = true }
        }
    }

    private func progress(_ title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IslandPalette.primary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Cancel", action: model.cancelAsk)
                .buttonStyle(IslandSecondaryButtonStyle())
                // ⌘. cancels an operation (HIG › Keyboards); Esc keeps closing the island.
                .keyboardShortcut(".", modifiers: .command)
                .help("Cancel (⌘.)")
        }
        .frame(maxHeight: .infinity)
    }

    private func failureView(_ failure: AskFailure) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandPalette.attention)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IslandPalette.primary)
                Text(failure.message)
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .help(failure.technicalDetail ?? "")
            Spacer(minLength: 8)
            if let fix = failure.fix {
                Button(fix == .openSettings ? "Open Settings" : "Open Privacy Settings") { model.performFix(fix) }
                    .buttonStyle(IslandActionButtonStyle())
                    .fixedSize()
            }
            dismissButton
        }
        .frame(maxHeight: .infinity)
    }

    /// While text streams, the header's action slot holds a spinner and Stop; once the reply
    /// is complete (or stopped) the same slot holds Copy and Dismiss. Copy waits for the end
    /// because a half-written reply is rarely what people want on the clipboard, and Stop
    /// keeps the text so it can be copied right away (HIG › Progress indicators: "When it's
    /// feasible, let people halt processing"; "Display a progress indicator in a consistent
    /// location").
    private func replyView(_ reply: AssistantReply, isStreaming: Bool, stoppedEarly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(replySource(reply, stoppedEarly: stoppedEarly))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("\(reply.provider.displayName) is writing")
                    Button("Stop", action: model.stopReply)
                        .buttonStyle(IslandSecondaryButtonStyle())
                        // ⌘. cancels an operation (HIG › Keyboards); Esc keeps closing the island.
                        .keyboardShortcut(".", modifiers: .command)
                        .accessibilityHint("Stops the reply and keeps the text written so far")
                        .help("Stop the reply and keep what’s written so far (⌘.)")
                } else {
                    Button(action: copy) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(IslandSecondaryButtonStyle())
                    .focused($copyFocused)
                    .accessibilityLabel(copied ? "Copied" : "Copy reply")
                    dismissButton
                }
            }
            ReplyText(text: reply.text, isStreaming: isStreaming)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply from \(reply.provider.displayName)")
    }

    private func replySource(_ reply: AssistantReply, stoppedEarly: Bool) -> String {
        var source = reply.provider.displayName
        if !reply.model.isEmpty { source += " · \(reply.model)" }
        if stoppedEarly { source += " · Stopped" }
        else if reply.truncated { source += " · Reply cut off at the length limit" }
        return source
    }

    private var dismissButton: some View {
        Button(action: model.dismissReply) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
        }
        .buttonStyle(IslandSecondaryButtonStyle())
        .accessibilityLabel("Dismiss")
        .help("Dismiss")
    }

    private func copy() {
        model.copyReply()
        copied = true
        AccessibilityNotification.Announcement("Reply copied").post()
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// Reply text that follows new text to the end while it streams, unless the person has
/// scrolled up to read; scrolling back to the end resumes following. Scrolling is never
/// animated: it happens up to 30 times a second (HIG › Motion: "avoid adding motion to UI
/// interactions that occur frequently"), which also keeps it Reduce Motion–friendly.
private struct ReplyText: View {
    let text: String
    let isStreaming: Bool
    @State private var following = true
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private nonisolated static let space = "ReplyTextScroll"
    private static let endID = "ReplyTextEnd"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(IslandPalette.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id(Self.endID)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                    contentDidChange(frame, proxy: proxy)
                }
            }
            .coordinateSpace(.named(Self.space))
            .scrollIndicators(.automatic)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        }
        // VoiceOver reads the text when it gets there instead of announcing every update;
        // the view model announces once when the reply is complete.
        .accessibilityAddTraits(isStreaming ? .updatesFrequently : [])
    }

    /// Same height, new position: the person scrolled, so follow only if they're at the
    /// end. New height: text arrived, so stay at the end if following.
    private func contentDidChange(_ frame: CGRect, proxy: ScrollViewProxy) {
        if frame.height == contentHeight {
            following = frame.maxY - viewportHeight <= 8
        } else {
            contentHeight = frame.height
            if following && isStreaming { proxy.scrollTo(Self.endID, anchor: .bottom) }
        }
    }
}
