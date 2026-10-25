import Foundation
import Testing
@testable import NotchPilotCore

@Suite("Chat turn lifecycle (island)")
struct ChatThreadTests {
    private func reply(_ text: String, truncated: Bool = false) -> AssistantReply {
        AssistantReply(text: text, provider: .claude, model: "claude-test", truncated: truncated)
    }

    private func draft(_ question: String, screen: Bool = false) -> ChatDraft {
        ChatDraft(question: question, includeScreen: screen)
    }

    /// A thread with one completed question/answer pair.
    private func oneExchange() -> ChatThread {
        var thread = ChatThread()
        _ = thread.send(question: "First?", purpose: .answer, draft: draft("First?"), includedScreen: false)
        thread.complete(reply("One."), stoppedEarly: false)
        return thread
    }

    @Test("a completed turn records the question, the reply and its source; history is the earlier turns")
    func completes() {
        var thread = oneExchange()
        let history = thread.send(question: "Second?", purpose: .answer, draft: draft("Second?", screen: true), includedScreen: true)
        #expect(history.map(\.text) == ["First?", "One."])
        #expect(thread.isPending)
        let result1 = thread.complete(reply("Two."), stoppedEarly: false)
        #expect(result1 == .added)
        #expect(thread.turns.map(\.text) == ["First?", "One.", "Second?", "Two."])
        let user = thread.info[thread.turns[2].id]
        #expect(user?.request == .question && user?.includedScreen == true)
        let assistant = thread.info[thread.turns[3].id]
        #expect(assistant?.provider == .claude && assistant?.model == "claude-test" && assistant?.stoppedEarly == false)
        #expect(thread.pendingDraft == nil)
    }

    @Test("Stop with partial text keeps it as a stopped turn")
    func stopWithText() {
        var thread = ChatThread()
        _ = thread.send(question: "Q", purpose: .answer, draft: draft("Q"), includedScreen: false)
        let result2 = thread.complete(reply("Partial "), stoppedEarly: true)
        #expect(result2 == .added)
        #expect(thread.turns.last?.text == "Partial")
        #expect(thread.info[thread.turns[1].id]?.stoppedEarly == true)
    }

    @Test("Stop before any text drops the turn and gives the draft back")
    func stopEmpty() {
        var thread = oneExchange()
        _ = thread.send(question: "Q", purpose: .answer, draft: draft("Q", screen: true), includedScreen: true)
        let pendingID = thread.turns.last!.id
        let result3 = thread.complete(reply("  "), stoppedEarly: true)
        #expect(result3 == .dropped(draft("Q", screen: true)))
        #expect(thread.turns.count == 2 && !thread.isPending)
        #expect(thread.info[pendingID] == nil)
    }

    @Test("an empty reply, even one cut off at the limit, adds no turn and gives the draft back")
    func emptyReply() {
        var thread = ChatThread()
        _ = thread.send(question: "Q", purpose: .answer, draft: draft("Q"), includedScreen: false)
        let result4 = thread.complete(reply("", truncated: true), stoppedEarly: false)
        #expect(result4 == .dropped(draft("Q")))
        #expect(thread.isEmpty)
    }

    @Test("Cancel during capture or a failure drops the pending turn and returns its draft")
    func abandon() {
        var thread = oneExchange()
        _ = thread.send(question: nil, purpose: .answer, draft: draft("", screen: true), includedScreen: true)
        #expect(thread.info[thread.turns.last!.id]?.request == .transcript)
        let result5 = thread.abandon()
        #expect(result5 == draft("", screen: true))
        #expect(thread.turns.map(\.text) == ["First?", "One."])
        #expect(thread.info.count == 2)
        let result6 = thread.abandon()
        #expect(result6 == nil)   // nothing pending
    }

    @Test("a summary turn sends no history, keeps no draft and becomes history for follow-ups")
    func summary() {
        var thread = oneExchange()
        let history = thread.send(question: "ignored", purpose: .summary, draft: draft("typed"), includedScreen: false)
        #expect(history.isEmpty)
        #expect(thread.pendingDraft == nil)
        #expect(thread.turns.last?.text == ChatSession.summaryMarker)
        #expect(thread.info[thread.turns.last!.id]?.request == .summary)
        #expect(thread.info[thread.turns.last!.id]?.includedScreen == false)
        thread.complete(reply("- Point 1\n- Point 2"), stoppedEarly: false)
        let next = thread.send(question: "Expand point 2", purpose: .answer, draft: draft("Expand point 2"), includedScreen: false)
        #expect(next.map(\.text) == ["First?", "One.", ChatSession.summaryMarker, "- Point 1\n- Point 2"])
    }

    @Test("a failed summary gives nothing back to the field")
    func failedSummary() {
        var thread = ChatThread()
        _ = thread.send(question: nil, purpose: .summary, draft: draft("typed"), includedScreen: false)
        let result7 = thread.abandon()
        #expect(result7 == nil)
        #expect(thread.isEmpty)
    }

    @Test("Ask Once → Chat carries the reply over only into an empty chat")
    func carryOver() {
        var thread = ChatThread()
        let result8 = thread.carryOver(question: "Q", purpose: .answer, includedScreen: true, reply: reply("A"), stoppedEarly: false)
        #expect(result8)
        #expect(thread.turns.map(\.text) == ["Q", "A"])
        #expect(thread.info[thread.turns[0].id]?.includedScreen == true)

        var busy = oneExchange()
        let result9 = busy.carryOver(question: "Q", purpose: .answer, includedScreen: false, reply: reply("A"), stoppedEarly: false)
        #expect(!result9)
        #expect(busy.turns.count == 2)

        var summary = ChatThread()
        let result10 = summary.carryOver(question: nil, purpose: .summary, includedScreen: false, reply: reply("S"), stoppedEarly: true)
        #expect(result10)
        #expect(summary.info[summary.turns[0].id]?.request == .summary)
        #expect(summary.info[summary.turns[1].id]?.stoppedEarly == true)
    }

    @Test("New Chat mid-stream: the replaced thread is kept intact for Undo, the new one is empty")
    func newChatMidStream() {
        var thread = oneExchange()
        _ = thread.send(question: "Q", purpose: .answer, draft: draft("Q"), includedScreen: false)
        // The island cancels the reply first (abandon), then replaces the thread.
        _ = thread.abandon()
        let previous = thread
        thread = ChatThread()
        #expect(thread.isEmpty && thread.pendingDraft == nil)
        #expect(previous.turns.map(\.text) == ["First?", "One."] && !previous.isPending)
    }

    @Test("a draft goes back only into an empty field, with its Include Screen choice")
    func draftRestore() {
        var field = ""
        var screen = false
        draft("Q", screen: true).restore(question: &field, includeScreen: &screen)
        #expect(field == "Q" && screen)

        var typed = "new"
        var keep = false
        draft("Q", screen: true).restore(question: &typed, includeScreen: &keep)
        #expect(typed == "new" && !keep)
    }

    @Test("sending while a turn is pending abandons it first, leaving no stale details")
    func sendWhilePending() {
        var thread = ChatThread()
        _ = thread.send(question: "A", purpose: .answer, draft: draft("A"), includedScreen: false)
        _ = thread.send(question: "B", purpose: .answer, draft: draft("B"), includedScreen: false)
        #expect(thread.turns.map(\.text) == ["B"])
        #expect(thread.info.count == 1)
    }
}
