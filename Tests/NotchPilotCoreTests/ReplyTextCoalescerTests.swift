import Testing
@testable import NotchPilotCore

@Suite("Reply text coalescing")
struct ReplyTextCoalescerTests {
    private let start = ContinuousClock.now

    private func at(_ ms: Int) -> ContinuousClock.Instant { start + .milliseconds(ms) }

    @Test("the first delta is shown immediately")
    func firstDeltaImmediate() {
        var coalescer = ReplyTextCoalescer(interval: .milliseconds(33))
        #expect(coalescer.append("Hel", at: at(0)) == "Hel")
        #expect(coalescer.pendingDeadline == nil)
    }

    @Test("deltas inside the interval are batched until the deadline")
    func batches() {
        var coalescer = ReplyTextCoalescer(interval: .milliseconds(33))
        _ = coalescer.append("A", at: at(0))
        #expect(coalescer.append("B", at: at(5)) == nil)
        #expect(coalescer.append("C", at: at(20)) == nil)
        #expect(coalescer.pendingDeadline == at(33))
        #expect(coalescer.flush(at: at(33)) == "ABC")
        #expect(coalescer.pendingDeadline == nil)
        #expect(coalescer.flush(at: at(40)) == nil)   // nothing new
    }

    @Test("a delta after the interval is shown at once")
    func afterInterval() {
        var coalescer = ReplyTextCoalescer(interval: .milliseconds(33))
        _ = coalescer.append("A", at: at(0))
        #expect(coalescer.append("B", at: at(50)) == "AB")
    }

    @Test("a fast stream publishes at most once per interval")
    func rateLimited() {
        var coalescer = ReplyTextCoalescer(interval: .milliseconds(33))
        var published = 0
        for ms in 0..<1_000 {   // one token per millisecond for a second
            if coalescer.append("x", at: at(ms)) != nil { published += 1 }
            if let deadline = coalescer.pendingDeadline, deadline <= at(ms) {
                if coalescer.flush(at: at(ms)) != nil { published += 1 }
            }
        }
        if coalescer.flush(at: at(1_000)) != nil { published += 1 }
        #expect(published <= 32)
        #expect(coalescer.text.count == 1_000)
    }

    @Test("empty deltas change nothing")
    func emptyDelta() {
        var coalescer = ReplyTextCoalescer()
        #expect(coalescer.append("", at: at(0)) == nil)
        #expect(coalescer.text.isEmpty)
        #expect(coalescer.flush(at: at(100)) == nil)
    }
}
