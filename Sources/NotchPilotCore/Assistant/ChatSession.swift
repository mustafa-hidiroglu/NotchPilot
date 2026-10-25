import Foundation

/// Makes chat history safe to send: providers reject a conversation that doesn't start
/// with a user turn or doesn't alternate, and history is capped so a long chat can't grow
/// a request without bound. `ReplyService` applies it to every request.
public enum ChatHistory {
    public static let maxTurns = 20
    public static let maxCharacters = 24_000

    /// What's left of `maxCharacters` for history once the new turn's transcript and
    /// question are counted (a summary sends no question).
    public static func characterBudget(for request: ReplyRequest) -> Int {
        let question = request.purpose == .summary ? 0 : (request.question?.count ?? 0)
        return max(0, maxCharacters - request.transcript.count - question)
    }

    /// The newest whole user/assistant pairs of `turns` that fit in `maxTurns` turns and
    /// `characterBudget` characters, oldest first.
    ///
    /// Malformed input is repaired by dropping turns, never by inventing them: an assistant
    /// turn with no user turn before it is dropped, of two user turns in a row only the later
    /// one is kept, a trailing user turn is dropped (the new turn follows the history), and
    /// pairs with blank text are dropped. Trimming stops at the first pair (counting back from
    /// the newest) that doesn't fit, so the history sent is always contiguous.
    public static func trimmed(_ turns: [ChatTurn], characterBudget: Int = maxCharacters) -> [ChatTurn] {
        var pairs: [(user: ChatTurn, assistant: ChatTurn)] = []
        var pendingUser: ChatTurn?
        for turn in turns {
            switch turn.role {
            case .user:
                pendingUser = turn
            case .assistant:
                guard let user = pendingUser else { continue }
                pendingUser = nil
                if !isBlank(user.text), !isBlank(turn.text) { pairs.append((user, turn)) }
            }
        }

        var kept: [ChatTurn] = []
        var characters = 0
        for pair in pairs.reversed() {
            let size = pair.user.text.count + pair.assistant.text.count
            guard kept.count + 2 <= maxTurns, characters + size <= characterBudget else { break }
            characters += size
            kept.insert(contentsOf: [pair.user, pair.assistant], at: 0)
        }
        return kept
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// An in-memory chat: the turns shown in the island and the history sent with each
/// follow-up. Lives until "New Chat" (`reset`) or app quit; never persisted.
///
/// Invariants: completed turns start with a user turn and alternate user/assistant. At most
/// one user turn is pending (asked, no reply yet); it is the last element of `turns` while
/// `isPending` is true and is never part of `history`.
///
/// Flow: `history` for the request, `begin(question:)`, then `complete(reply:stoppedEarly:)`
/// when the reply ends, or `discardPending()` when it was refused or failed.
public struct ChatSession: Sendable, Equatable {
    // History user turns carry no transcript, so the markers say the turn referred to the
    // transcript as it was then; the model shouldn't read them as about the current one.
    /// Recorded for an Ask without a typed question.
    public static let respondMarker = "(Asked about the transcript at the time)"
    /// Recorded for a Summarize turn.
    public static let summaryMarker = "(Asked for a summary of the transcript at the time)"

    public private(set) var turns: [ChatTurn] = []
    /// True between `begin` and `complete`/`discardPending`.
    public private(set) var isPending = false

    public init() {}

    public var isEmpty: Bool { turns.isEmpty }

    /// Appends the pending user turn and returns its text: the trimmed question, or
    /// `respondMarker` when it is empty. A turn still pending is discarded first.
    @discardableResult
    public mutating func begin(question: String?) -> String {
        discardPending()
        let trimmed = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = trimmed.isEmpty ? Self.respondMarker : trimmed
        turns.append(ChatTurn(role: .user, text: text))
        isPending = true
        return text
    }

    /// Answers the pending user turn with `reply`. A stopped reply keeps the partial text
    /// the person saw; a reply with no text (for example stopped before the first word) can't
    /// be sent back as history, so the pending turn is discarded instead. Does nothing when
    /// no turn is pending.
    public mutating func complete(reply: String, stoppedEarly: Bool) {
        guard isPending else { return }
        let text = stoppedEarly ? reply.trimmingCharacters(in: .whitespacesAndNewlines) : reply
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            discardPending()
            return
        }
        turns.append(ChatTurn(role: .assistant, text: text))
        isPending = false
    }

    /// Removes the pending user turn (refused or failed reply), so history stays alternating.
    public mutating func discardPending() {
        guard isPending else { return }
        turns.removeLast()
        isPending = false
    }

    /// The completed turns, for `ReplyRequest.history`. Not trimmed here: `ReplyService`
    /// trims it against the whole request (transcript and question included).
    public var history: [ChatTurn] {
        isPending ? Array(turns.dropLast()) : turns
    }

    public mutating func reset() {
        turns = []
        isPending = false
    }
}
