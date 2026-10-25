import Foundation

/// What the island shows for a chat turn that the history itself doesn't carry.
public struct ChatTurnInfo: Sendable, Equatable {
    public enum Request: Sendable, Equatable {
        /// A typed question (the turn's text).
        case question
        /// No question: respond to the transcript.
        case transcript
        case summary
    }

    /// User turns: what was asked, and whether a screenshot went with it.
    public var request: Request
    public var includedScreen: Bool
    /// Assistant turns: where the reply came from and how it ended.
    public var provider: AIProvider?
    public var model: String
    public var truncated: Bool
    public var stoppedEarly: Bool

    public init(request: Request = .question, includedScreen: Bool = false, provider: AIProvider? = nil,
                model: String = "", truncated: Bool = false, stoppedEarly: Bool = false) {
        self.request = request
        self.includedScreen = includedScreen
        self.provider = provider
        self.model = model
        self.truncated = truncated
        self.stoppedEarly = stoppedEarly
    }
}

/// The question field's state when a chat question was sent, given back if the turn
/// doesn't complete so the person can send it again.
public struct ChatDraft: Sendable, Equatable {
    public var question: String
    public var includeScreen: Bool

    public init(question: String, includeScreen: Bool) {
        self.question = question
        self.includeScreen = includeScreen
    }

    /// Puts the draft back, unless the person has started typing another question.
    public func restore(question field: inout String, includeScreen: inout Bool) {
        guard field.isEmpty else { return }
        field = question
        includeScreen = self.includeScreen
    }
}

/// The island's chat: a `ChatSession` (the turns and the history sent with follow-ups) plus
/// what the island shows per turn and the draft to give back when a turn fails. Pure, so the
/// whole turn lifecycle is unit tested; `IslandViewModel` maps reply phases onto it.
///
/// Lifecycle of one turn: `send` → (`complete` | `abandon`). `complete` with no reply text
/// adds no assistant turn and returns the draft, like `abandon`.
public struct ChatThread: Sendable, Equatable {
    public private(set) var session = ChatSession()
    public private(set) var info: [ChatTurn.ID: ChatTurnInfo] = [:]
    /// Field state of the pending question; nil for a summary (it doesn't use the field).
    public private(set) var pendingDraft: ChatDraft?

    public init() {}

    public var turns: [ChatTurn] { session.turns }
    public var isEmpty: Bool { session.isEmpty }
    public var isPending: Bool { session.isPending }

    public enum Completion: Sendable, Equatable {
        /// The reply became an assistant turn.
        case added
        /// The reply had no text, so neither it nor its question was kept; the draft (if
        /// any) should go back into the field.
        case dropped(ChatDraft?)
    }

    /// Starts a turn and returns the history to send with it (oldest first; `ReplyService`
    /// trims it against the whole request). A summary
    /// covers the transcript only, so it is sent with no history; it is still recorded as a
    /// turn so later follow-ups have it.
    ///
    /// - Parameters:
    ///   - question: the trimmed question, or nil for none (ignored for a summary).
    ///   - draft: the field text and Include Screen choice to give back if the turn fails.
    ///   - includedScreen: a screenshot goes with this turn.
    public mutating func send(question: String?, purpose: AskPurpose, draft: ChatDraft?, includedScreen: Bool) -> [ChatTurn] {
        if session.isPending { abandon() }
        let isSummary = purpose == .summary
        let history = isSummary ? [] : session.history
        let text = session.begin(question: isSummary ? ChatSession.summaryMarker : question)
        if let user = session.turns.last {
            info[user.id] = ChatTurnInfo(request: Self.request(for: text, isSummary: isSummary), includedScreen: includedScreen)
        }
        pendingDraft = isSummary ? nil : draft
        return history
    }

    /// Answers the pending turn with `reply`. Stopped replies keep the partial text.
    @discardableResult
    public mutating func complete(_ reply: AssistantReply, stoppedEarly: Bool) -> Completion {
        guard session.isPending, let pending = session.turns.last else { return .dropped(nil) }
        let countBefore = session.turns.count
        session.complete(reply: reply.text, stoppedEarly: stoppedEarly)
        let draft = pendingDraft
        pendingDraft = nil
        // Added exactly when the session grew by the reply (a dropped reply shrinks it, and
        // the last turn is then an earlier reply).
        if session.turns.count == countBefore + 1, let turn = session.turns.last {
            info[turn.id] = ChatTurnInfo(provider: reply.provider, model: reply.model,
                                         truncated: reply.truncated, stoppedEarly: stoppedEarly)
            return .added
        }
        info[pending.id] = nil
        return .dropped(draft)
    }

    /// Drops the pending turn (cancelled, refused or failed) and returns its draft.
    @discardableResult
    public mutating func abandon() -> ChatDraft? {
        if session.isPending, let pending = session.turns.last { info[pending.id] = nil }
        session.discardPending()
        let draft = pendingDraft
        pendingDraft = nil
        return draft
    }

    /// Continues a one-time Ask in the chat (switching Ask Once → Chat with its reply
    /// showing). Only into an empty chat, so it never mixes into an earlier conversation.
    /// Returns false when nothing was carried over.
    @discardableResult
    public mutating func carryOver(question: String?, purpose: AskPurpose, includedScreen: Bool,
                                   reply: AssistantReply, stoppedEarly: Bool) -> Bool {
        guard session.isEmpty else { return false }
        _ = send(question: question, purpose: purpose, draft: nil, includedScreen: includedScreen)
        return complete(reply, stoppedEarly: stoppedEarly) == .added
    }

    private static func request(for text: String, isSummary: Bool) -> ChatTurnInfo.Request {
        if isSummary { return .summary }
        return text == ChatSession.respondMarker ? .transcript : .question
    }
}
