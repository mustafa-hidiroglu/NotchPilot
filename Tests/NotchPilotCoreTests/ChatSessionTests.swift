import Foundation
import Testing
@testable import NotchPilotCore

private func user(_ text: String) -> ChatTurn { ChatTurn(role: .user, text: text) }
private func assistant(_ text: String) -> ChatTurn { ChatTurn(role: .assistant, text: text) }

/// Roles in order, e.g. "UAUA".
private func roles(_ turns: [ChatTurn]) -> String {
    String(turns.map { $0.role == .user ? "U" : "A" })
}

@Suite("Chat history")
struct ChatHistoryTests {
    @Test("well-formed history passes through unchanged")
    func passesThrough() {
        let turns = [user("a"), assistant("b"), user("c"), assistant("d")]
        #expect(ChatHistory.trimmed(turns) == turns)
        #expect(ChatHistory.trimmed([]) == [])
    }

    @Test("leading assistant, doubled user and trailing user turns are dropped")
    func repairsShape() {
        let first = user("second ask")
        let reply = assistant("reply")
        let turns = [assistant("orphan"), user("first ask"), first, reply, user("unanswered")]
        #expect(ChatHistory.trimmed(turns) == [first, reply])
    }

    @Test("pairs with blank text are dropped, keeping the rest alternating")
    func dropsBlankPairs() {
        let turns = [user("a"), assistant(" \n"), user("c"), assistant("d"), user(""), assistant("f")]
        #expect(ChatHistory.trimmed(turns) == [turns[2], turns[3]])
    }

    @Test("keeps at most the newest 20 turns, as whole pairs")
    func capsTurns() {
        let turns = (0..<15).flatMap { [user("q\($0)"), assistant("a\($0)")] }
        let kept = ChatHistory.trimmed(turns)
        #expect(kept.count == ChatHistory.maxTurns)
        #expect(kept == Array(turns.suffix(20)))
        #expect(roles(kept) == String(repeating: "UA", count: 10))
    }

    @Test("keeps the newest pairs that fit the character budget and stops at the first that doesn't")
    func capsCharacters() {
        let big = String(repeating: "x", count: 11_000)
        let turns = [user("old"), assistant("tiny"), user(big), assistant(big), user("q"), assistant(String(repeating: "y", count: 3_000))]
        // The middle pair (22 000) no longer fits after the newest (3 001), so the older tiny pair is dropped too.
        #expect(ChatHistory.trimmed(turns) == Array(turns.suffix(2)))
        #expect(ChatHistory.trimmed(turns, characterBudget: 30_000) == turns)
        #expect(ChatHistory.trimmed(turns, characterBudget: 100) == [])
    }

    @Test("the budget is what the new turn's transcript and question leave of the cap")
    func budget() {
        let transcript = String(repeating: "t", count: 6_000)
        #expect(ChatHistory.characterBudget(for: ReplyRequest(transcript: transcript, question: "four", systemPrompt: "s"))
            == ChatHistory.maxCharacters - 6_004)
        #expect(ChatHistory.characterBudget(for: ReplyRequest(transcript: transcript, question: "ignored", systemPrompt: "s", purpose: .summary))
            == ChatHistory.maxCharacters - 6_000)
        #expect(ChatHistory.characterBudget(for: ReplyRequest(transcript: String(repeating: "t", count: 30_000), systemPrompt: "s")) == 0)
    }
}

@Suite("Chat session")
struct ChatSessionTests {
    @Test("begin records the trimmed question, or the marker for an empty one, as a pending user turn")
    func begin() {
        var chat = ChatSession()
        #expect(chat.isEmpty)
        #expect(chat.begin(question: "  When?\n") == "When?")
        #expect(chat.isPending)
        #expect(chat.turns.map(\.text) == ["When?"])
        chat.complete(reply: "Friday.", stoppedEarly: false)

        #expect(chat.begin(question: nil) == ChatSession.respondMarker)
        chat.complete(reply: "Ok.", stoppedEarly: false)
        #expect(chat.begin(question: "   ") == "(Asked about the transcript at the time)")
    }

    @Test("complete appends the reply and clears pending; history then alternates from a user turn")
    func complete() {
        var chat = ChatSession()
        chat.begin(question: "a")
        chat.complete(reply: "b", stoppedEarly: false)
        chat.begin(question: "c")
        chat.complete(reply: "d", stoppedEarly: false)
        #expect(!chat.isPending)
        #expect(roles(chat.turns) == "UAUA")
        #expect(chat.history == chat.turns)
    }

    @Test("history never includes the pending turn, whether asked before or after begin")
    func historyExcludesPending() {
        var chat = ChatSession()
        chat.begin(question: "a")
        chat.complete(reply: "b", stoppedEarly: false)
        let before = chat.history
        chat.begin(question: "c")
        #expect(chat.history == before)
        #expect(roles(chat.turns) == "UAU")
        #expect(roles(before) == "UA")
    }

    @Test("a refused or failed reply discards the pending user turn")
    func discard() {
        var chat = ChatSession()
        chat.begin(question: "a")
        chat.complete(reply: "b", stoppedEarly: false)
        chat.begin(question: "c")
        chat.discardPending()
        #expect(!chat.isPending)
        #expect(chat.turns.map(\.text) == ["a", "b"])
        chat.discardPending()   // nothing pending: no change
        #expect(chat.turns.count == 2)
    }

    @Test("a stopped reply keeps its partial text; one stopped before any text discards the pair")
    func stopped() {
        var chat = ChatSession()
        chat.begin(question: "a")
        chat.complete(reply: "partial ", stoppedEarly: true)
        #expect(chat.turns.map(\.text) == ["a", "partial"])

        chat.begin(question: "c")
        chat.complete(reply: "", stoppedEarly: true)
        #expect(!chat.isPending)
        #expect(chat.turns.map(\.text) == ["a", "partial"])
    }

    @Test("begin while a turn is pending replaces it; complete without one does nothing")
    func outOfOrder() {
        var chat = ChatSession()
        chat.complete(reply: "stray", stoppedEarly: false)
        #expect(chat.isEmpty)
        chat.begin(question: "first")
        chat.begin(question: "second")
        #expect(chat.turns.map(\.text) == ["second"])
        chat.complete(reply: "r", stoppedEarly: false)
        chat.complete(reply: "again", stoppedEarly: false)
        #expect(roles(chat.turns) == "UA")
    }

    @Test("history is every completed turn, untrimmed (ReplyService trims it against the whole request)")
    func historyUntrimmed() {
        var chat = ChatSession()
        for index in 0..<12 {
            chat.begin(question: "q\(index)")
            chat.complete(reply: "a\(index)", stoppedEarly: false)
        }
        #expect(chat.history.count == 24)
        #expect(chat.history == chat.turns)
    }

    @Test("reset forgets everything, including a pending turn")
    func reset() {
        var chat = ChatSession()
        chat.begin(question: "a")
        chat.complete(reply: "b", stoppedEarly: false)
        chat.begin(question: "c")
        chat.reset()
        #expect(chat == ChatSession())
        #expect(chat.history == [])
    }
}
