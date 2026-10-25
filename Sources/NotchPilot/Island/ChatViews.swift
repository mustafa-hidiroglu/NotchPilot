import NotchPilotCore
import SwiftUI

// Mode row and Chat conversation of the expanded island. Same tokens as IslandView and
// AssistantViews: black opaque surface, white text, black labels on light fills, yellow =
// needs attention. Turns are told apart by position and shape, not colour: your turns sit
// on the trailing side in a quiet filled bubble, replies run full width under a source line
// that names the AI that wrote them (HIG › Generative AI: "Clearly identify when and where
// you use AI").

/// Ask Once / Chat, plus Summarize and New Chat when they apply.
struct ModeRow: View {
    let model: IslandViewModel

    static let height: CGFloat = 24

    var body: some View {
        HStack(spacing: 8) {
            // A segmented control: two closely related choices that change the view, with
            // the selection always visible (HIG › Segmented controls), text-only segments.
            Picker("Ask Mode", selection: Binding(get: { model.askMode }, set: { model.setAskMode($0) })) {
                Text(AskMode.once.settingsName).tag(AskMode.once)
                Text(AskMode.chat.settingsName).tag(AskMode.chat)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.askPhase.isBusy)
            .help("Ask Once (⌘1): one question, one reply. Chat (⌘2): follow-up questions include the earlier turns.")
            .accessibilityLabel("Ask mode")
            .background(modeShortcuts)

            Spacer(minLength: 8)

            // Only on request, never automatic: nothing is sent until it is pressed.
            if model.offersSummary {
                Button(action: model.summarize) {
                    Label("Summarize", systemImage: "list.bullet")
                }
                .buttonStyle(IslandSecondaryButtonStyle())
                .disabled(model.askPhase.isBusy)
                .accessibilityLabel("Summarize transcript")
                .help("Send the transcript to \(model.provider.displayName) for key points, decisions and action items")
                .transition(.opacity)
            }

            if model.askMode == .chat {
                Button(action: model.newChat) {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(IslandSecondaryButtonStyle())
                // ⌘N opens something new (HIG › Keyboards); works while the panel is key.
                .keyboardShortcut("n", modifiers: .command)
                // Not while a reply is in progress (Stop it first); undoable with ⌘Z.
                .disabled(!model.canStartNewChat)
                .help("Start a new conversation (⌘N). You can undo it with ⌘Z.")
                .transition(.opacity)
            }
        }
        .frame(height: Self.height)
    }

    /// ⌘1 / ⌘2 switch modes while the island is key. A segmented control's segments can't
    /// carry shortcuts, so they live on hidden buttons (hidden from VoiceOver too; the
    /// control itself is the accessible element).
    private var modeShortcuts: some View {
        ZStack {
            Button("Ask Once") { model.setAskMode(.once) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Chat") { model.setAskMode(.chat) }
                .keyboardShortcut("2", modifiers: .command)
        }
        .disabled(model.askPhase.isBusy)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// The conversation: completed turns, then the turn in progress (pending question, progress,
/// streaming reply or failure). Follows new text to the end unless the person has scrolled
/// up to read; sending a new question always returns to the end. Scrolling is never
/// animated (HIG › Motion: "avoid adding motion to UI interactions that occur frequently").
struct ChatConversation: View {
    let model: IslandViewModel
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var following = true
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var copiedTurn: ChatTurn.ID?
    @State private var copiedReset: Task<Void, Never>?

    private nonisolated static let space = "ChatConversationScroll"
    private static let endID = "ChatConversationEnd"

    private var secondary: Color {
        contrast == .increased ? IslandPalette.secondaryHighContrast : IslandPalette.secondary
    }

    var body: some View {
        Group {
            if model.chat.isEmpty && !showsTail {
                emptyState
            } else {
                conversation
            }
        }
        .overlay(alignment: .bottom) {
            if model.showsChatClearedNotice {
                clearedNotice
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: model.config.animation.reducedMotionFade), value: model.showsChatClearedNotice)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: model.config.layout.expandedCornerRadius - model.config.layout.contentInset,
                                     style: .continuous).fill(IslandPalette.container))
        .clipShape(RoundedRectangle(cornerRadius: model.config.layout.expandedCornerRadius - model.config.layout.contentInset,
                                    style: .continuous))
        .onDisappear { copiedReset?.cancel() }
    }

    /// A turn in progress or a failure notice is shown at the end of the conversation.
    private var showsTail: Bool {
        switch model.askPhase {
        case .capturingScreen, .waiting, .streaming, .failed: true
        case .idle, .replied: false
        }
    }

    /// "Chat cleared · Undo" for a few seconds after New Chat. ⌘Z (Edit › Undo New Chat) is
    /// the standard path (HIG › Undo and redo: "support the standard keyboard shortcuts"),
    /// but an accessory app's Edit menu is never visible, so the notice makes the undo
    /// discoverable right where the chat disappeared.
    private var clearedNotice: some View {
        HStack(spacing: 8) {
            Text("Chat cleared")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IslandPalette.primary)
            Spacer(minLength: 8)
            Button("Undo", action: model.undoNewChat)
                .buttonStyle(IslandSecondaryButtonStyle())
                .accessibilityHint("Brings back the previous conversation")
                .help("Bring back the previous conversation (⌘Z)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.16)))
    }

    /// Invites the first question and says what a chat keeps (HIG › Writing: empty views
    /// invite the next action).
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(secondary)
                .accessibilityHidden(true)
            Text("Ask about what’s playing, then keep asking.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandPalette.primary)
            Text("Follow-up questions include the earlier turns. The chat stays in memory until New Chat or quit.")
                .font(.system(size: 12))
                .foregroundStyle(secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.chat.turns) { turn in
                        switch turn.role {
                        case .user: userTurn(turn)
                        case .assistant: assistantTurn(turn)
                        }
                    }
                    tail
                    Color.clear.frame(height: 1).id(Self.endID)
                }
                .padding(12)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                    contentDidChange(frame, proxy: proxy)
                }
            }
            .coordinateSpace(.named(Self.space))
            .scrollIndicators(.automatic)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .onAppear { proxy.scrollTo(Self.endID, anchor: .bottom) }
            // A new question (or New Chat) returns to the end and resumes following.
            .onChange(of: model.chat.turns.last?.id) { _, _ in
                following = true
                proxy.scrollTo(Self.endID, anchor: .bottom)
            }
        }
    }

    /// Same height, new position: the person scrolled, so follow only if they're at the
    /// end. New height: text arrived, so stay at the end if following.
    private func contentDidChange(_ frame: CGRect, proxy: ScrollViewProxy) {
        if frame.height == contentHeight {
            following = frame.maxY - viewportHeight <= 8
        } else {
            contentHeight = frame.height
            if following { proxy.scrollTo(Self.endID, anchor: .bottom) }
        }
    }

    // MARK: Turns

    private func userTurn(_ turn: ChatTurn) -> some View {
        let info = model.chat.info[turn.id] ?? ChatTurnInfo()
        return HStack(spacing: 0) {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 4) {
                switch info.request {
                case .question:
                    Text(turn.text)
                        .font(.system(size: 13))
                        .foregroundStyle(IslandPalette.primary)
                        .textSelection(.enabled)
                case .transcript:
                    Label("About the transcript", systemImage: "waveform")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(IslandPalette.primary)
                case .summary:
                    Label("Summarize the transcript", systemImage: "list.bullet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(IslandPalette.primary)
                }
                if info.includedScreen {
                    Label("With screenshot", systemImage: "display")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // White 14% over the 8% container is about #353535: primary text on it is 10.6:1.
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.14)))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(userAccessibilityLabel(turn, info: info))
        .accessibilityAction(named: "Copy") { model.copyChatTurn(turn) }
        .contextMenu { Button("Copy") { model.copyChatTurn(turn) } }
    }

    private func userAccessibilityLabel(_ turn: ChatTurn, info: ChatTurnInfo) -> String {
        let request = switch info.request {
        case .question: turn.text
        case .transcript: "About the transcript"
        case .summary: "Summarize the transcript"
        }
        return "You: \(request)\(info.includedScreen ? ", with screenshot" : "")"
    }

    private func assistantTurn(_ turn: ChatTurn) -> some View {
        let info = model.chat.info[turn.id] ?? ChatTurnInfo()
        let isLatest = turn.id == model.chat.turns.last?.id && !model.askPhase.isBusy
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                sourceLabel(provider: info.provider ?? model.provider, model: info.model,
                            stoppedEarly: info.stoppedEarly, truncated: info.truncated)
                Spacer(minLength: 8)
                // Copy on the latest reply, where it's most often wanted; every turn also has
                // Copy in its context menu, and the text is selectable.
                if isLatest {
                    Button { copy(turn) } label: {
                        Label(copiedTurn == turn.id ? "Copied" : "Copy",
                              systemImage: copiedTurn == turn.id ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(IslandSecondaryButtonStyle())
                    .accessibilityHint("Copies this reply")
                }
            }
            .frame(height: ModeRow.height)
            Text(turn.text)
                .font(.system(size: 13))
                .foregroundStyle(IslandPalette.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply from \((info.provider ?? model.provider).displayName)")
        .accessibilityAction(named: "Copy") { copy(turn) }
        .contextMenu { Button("Copy") { model.copyChatTurn(turn) } }
    }

    private func sourceLabel(provider: AIProvider, model name: String, stoppedEarly: Bool, truncated: Bool) -> some View {
        var source = provider.displayName
        if !name.isEmpty { source += " · \(name)" }
        if stoppedEarly { source += " · Stopped" }
        else if truncated { source += " · Cut off at the length limit" }
        return Text(source)
            // VoiceOver reads commas, not the middle dot.
            .accessibilityLabel(source.replacingOccurrences(of: " · ", with: ", "))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // MARK: Turn in progress

    @ViewBuilder private var tail: some View {
        switch model.askPhase {
        case .idle, .replied:
            EmptyView()
        case .capturingScreen:
            progress("Capturing Screen…")
        case .waiting(let provider):
            progress(model.askPurpose == .summary ? "\(provider.displayName) is summarizing the transcript…"
                                                  : "Waiting for \(provider.displayName)…")
        case .streaming(let reply):
            streaming(reply)
        case .failed(let failure):
            failureNotice(failure)
        }
    }

    /// Spinner and Cancel in the place the reply will appear (HIG › Progress indicators:
    /// "When it's feasible, let people halt processing").
    private func progress(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Cancel", action: model.cancelAsk)
                .buttonStyle(IslandSecondaryButtonStyle())
                // ⌘. cancels an operation (HIG › Keyboards); Esc keeps closing the island.
                .keyboardShortcut(".", modifiers: .command)
                .help("Cancel (⌘.)")
        }
        .frame(height: ModeRow.height)
    }

    private func streaming(_ reply: AssistantReply) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                sourceLabel(provider: reply.provider, model: reply.model, stoppedEarly: false, truncated: false)
                Spacer(minLength: 8)
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("\(reply.provider.displayName) is writing")
                Button("Stop", action: model.stopReply)
                    .buttonStyle(IslandSecondaryButtonStyle())
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityHint("Stops the reply and keeps the text written so far")
                    .help("Stop the reply and keep what’s written so far (⌘.)")
            }
            .frame(height: ModeRow.height)
            Text(reply.text)
                .font(.system(size: 13))
                .foregroundStyle(IslandPalette.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // VoiceOver reads the text when it gets there instead of announcing every update;
        // the view model announces once when the reply is complete.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply from \(reply.provider.displayName)")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The turn didn't complete: say what happened and what to do; the question is back in
    /// the field so it can be sent again (HIG › Generative AI: "If something goes wrong,
    /// describe what happened in plain language and offer a clear next step").
    private func failureNotice(_ failure: AskFailure) -> some View {
        HStack(alignment: .top, spacing: 8) {
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
            Button(action: model.dismissReply) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(IslandSecondaryButtonStyle())
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
        }
    }

    private func copy(_ turn: ChatTurn) {
        model.copyChatTurn(turn)
        copiedTurn = turn.id
        AccessibilityNotification.Announcement("Reply copied").post()
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedTurn = nil
        }
    }
}
