import NotchPilotCore
import SwiftUI

// Assistant rows of the expanded island: live transcript, Ask row and the output area
// (progress, error or reply). Same tokens as IslandView: black opaque surface, white text,
// black labels on light fills, yellow = needs attention, teal stays the level meter's.

/// Secondary capsule button for actions inside the output area (Copy, Cancel): light label
/// on a dark fill so it ranks below the light-filled primary actions. 24 pt tall
/// (HIG › Accessibility: macOS minimum control size is 20 × 20 pt).
struct IslandSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(IslandPalette.primary)
            .padding(.horizontal, 10)
            .frame(minWidth: 24, minHeight: 24)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.24 : 0.16)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
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
                transcriptText(placeholder: "A live transcript appears here while capturing.")
            case .needsPermission:
                notice("Speech recognition needs permission.") {
                    Button("Continue", action: model.requestSpeechPermission)
                        .buttonStyle(IslandActionButtonStyle())
                        .accessibilityHint("Shows the macOS Speech Recognition permission prompt")
                }
            case .permissionDenied:
                notice("Speech recognition is turned off for NotchPilot.") {
                    Button("Open Privacy Settings", action: model.openSpeechPrivacySettings)
                        .buttonStyle(IslandActionButtonStyle())
                        .accessibilityHint("Opens Privacy & Security settings for Speech Recognition")
                }
            case .unavailable(let reason), .failed(let reason):
                notice(reason) { EmptyView() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
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
                      prompt: Text("Ask about what’s playing…").foregroundStyle(IslandPalette.secondary))
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
                progress("Asking \(provider.displayName)…", detail: "Waiting for a reply.")
            case .failed(let failure):
                failureView(failure)
            case .replied(let reply):
                replyView(reply)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: model.config.layout.expandedCornerRadius - model.config.layout.contentInset,
                                     style: .continuous).fill(IslandPalette.container))
        .onDisappear { copiedReset?.cancel() }
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

    private func replyView(_ reply: AssistantReply) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(replySource(reply))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(IslandSecondaryButtonStyle())
                .accessibilityLabel(copied ? "Copied" : "Copy reply")
                dismissButton
            }
            ScrollView {
                Text(reply.text)
                    .font(.system(size: 13))
                    .foregroundStyle(IslandPalette.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply from \(reply.provider.displayName)")
    }

    private func replySource(_ reply: AssistantReply) -> String {
        var source = "\(reply.provider.displayName) · \(reply.model)"
        if reply.truncated { source += " · Reply cut off at the length limit" }
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
