import Testing
@testable import NotchPilotCore

@Suite("Ask shortcut double press")
struct DoublePressTests {
    private let start = ContinuousClock.now

    private func at(_ ms: Int) -> ContinuousClock.Instant { start + .milliseconds(ms) }

    @Test("the system double-click interval is clamped to 0.2–0.5 s")
    func intervalClamp() {
        #expect(DoublePressDetector.interval(systemDoubleClickInterval: 0.05) == .milliseconds(200))
        #expect(DoublePressDetector.interval(systemDoubleClickInterval: 0.3) == .milliseconds(300))
        #expect(DoublePressDetector.interval(systemDoubleClickInterval: 0.5) == .milliseconds(500))
        #expect(DoublePressDetector.interval(systemDoubleClickInterval: 5) == .milliseconds(500))
        #expect(DoublePressDetector.interval(systemDoubleClickInterval: .nan) == .milliseconds(500))
    }

    @Test("a press inside the interval is a double press; the boundary counts")
    func detects() {
        var detector = DoublePressDetector(interval: .milliseconds(300))
        #expect(detector.register(at: at(0)) == .single)
        #expect(detector.register(at: at(300)) == .double)
    }

    @Test("a press after the interval is a new single press")
    func slow() {
        var detector = DoublePressDetector(interval: .milliseconds(300))
        #expect(detector.register(at: at(0)) == .single)
        #expect(detector.register(at: at(301)) == .single)
        #expect(detector.register(at: at(400)) == .double)   // measured from the latest single
    }

    @Test("a double press consumes the pair, so a third quick press is single")
    func triple() {
        var detector = DoublePressDetector(interval: .milliseconds(300))
        _ = detector.register(at: at(0))
        #expect(detector.register(at: at(100)) == .double)
        #expect(detector.register(at: at(200)) == .single)
        detector.reset()
        #expect(detector.register(at: at(250)) == .single)
    }

    @Test("a clock that goes backwards never yields a double press")
    func backwards() {
        var detector = DoublePressDetector(interval: .milliseconds(300))
        _ = detector.register(at: at(500))
        #expect(detector.register(at: at(400)) == .single)
    }

    // MARK: Router

    private func router() -> QuickAskPressRouter { QuickAskPressRouter(interval: .milliseconds(300)) }

    @Test("one press opens at once")
    func opens() {
        var r = router()
        let result1 = r.press(at: at(0), isOpen: false, doublePressEnabled: true)
        #expect(result1 == .open)
    }

    @Test("a quick second press switches mode")
    func switches() {
        var r = router()
        _ = r.press(at: at(0), isOpen: false, doublePressEnabled: true)
        let result2 = r.press(at: at(200), isOpen: true, doublePressEnabled: true)
        #expect(result2 == .switchMode)
    }

    @Test("a later press closes, and a press after the switch closes too")
    func closes() {
        var r = router()
        _ = r.press(at: at(0), isOpen: false, doublePressEnabled: true)
        let result3 = r.press(at: at(900), isOpen: true, doublePressEnabled: true)
        #expect(result3 == .close)

        var s = router()
        _ = s.press(at: at(0), isOpen: false, doublePressEnabled: true)
        _ = s.press(at: at(100), isOpen: true, doublePressEnabled: true)
        let result4 = s.press(at: at(200), isOpen: true, doublePressEnabled: true)
        #expect(result4 == .close)
    }

    @Test("with double press off, a quick second press closes as before")
    func doubleOff() {
        var r = router()
        _ = r.press(at: at(0), isOpen: false, doublePressEnabled: false)
        let result5 = r.press(at: at(100), isOpen: true, doublePressEnabled: false)
        #expect(result5 == .close)
    }

    @Test("a quick press after closing reopens instead of switching")
    func closeThenQuickPress() {
        var r = router()
        _ = r.press(at: at(0), isOpen: false, doublePressEnabled: true)
        _ = r.press(at: at(1_000), isOpen: true, doublePressEnabled: true)   // close
        let result6 = r.press(at: at(1_100), isOpen: false, doublePressEnabled: true)
        #expect(result6 == .open)
    }

    @Test("if the island was closed another way, a quick press reopens it")
    func closedElsewhere() {
        var r = router()
        _ = r.press(at: at(0), isOpen: false, doublePressEnabled: true)
        // Esc or a click outside closed it within the interval.
        let result7 = r.press(at: at(150), isOpen: false, doublePressEnabled: true)
        #expect(result7 == .open)
    }

    @Test("reset on collapse: an open, collapse, reopen sequence never reads as a double press")
    func resetOnCollapse() {
        var r = router()
        _ = r.press(at: at(0), isOpen: false, doublePressEnabled: true)
        r.reset()   // collapsed by Esc
        _ = r.press(at: at(100), isOpen: false, doublePressEnabled: true)   // reopen
        let result8 = r.press(at: at(150), isOpen: true, doublePressEnabled: true)
        #expect(result8 == .switchMode)
        r.reset()
        let result9 = r.press(at: at(200), isOpen: true, doublePressEnabled: true)
        #expect(result9 == .close)
    }

    @Test("the opening mode: kept when expanded, Chat for an unseen chat reply, else one-press mode")
    func modeForOpening() {
        typealias R = QuickAskPressRouter
        #expect(R.modeForOpening(singlePress: .once, current: .chat, isExpanded: false, hasUnseenChatReply: false) == .once)
        #expect(R.modeForOpening(singlePress: .chat, current: .once, isExpanded: false, hasUnseenChatReply: false) == .chat)
        #expect(R.modeForOpening(singlePress: .once, current: .once, isExpanded: false, hasUnseenChatReply: true) == .chat)
        #expect(R.modeForOpening(singlePress: .once, current: .chat, isExpanded: true, hasUnseenChatReply: false) == .chat)
        #expect(R.modeForOpening(singlePress: .chat, current: .once, isExpanded: true, hasUnseenChatReply: true) == .once)
    }

    // MARK: Summary eligibility

    @Test("Summarize is offered only after capture stops with at least 30 words")
    func summary() {
        let short = Transcript(finalText: Array(repeating: "word", count: 29).joined(separator: " "))
        let enough = Transcript(finalText: Array(repeating: "word", count: 25).joined(separator: " "),
                                partialText: "and five more words here")
        #expect(SummaryEligibility.wordCount(enough.fullText) == 30)
        #expect(!SummaryEligibility.offersSummary(for: short, isCapturing: false))
        #expect(SummaryEligibility.offersSummary(for: enough, isCapturing: false))
        #expect(!SummaryEligibility.offersSummary(for: enough, isCapturing: true))
        #expect(SummaryEligibility.wordCount("  Hello, world!  It’s here. ") == 4)
    }

    @Test("a summary never sends a screenshot; an answer may")
    func summaryHasNoScreenshot() {
        #expect(!AskPurpose.summary.sendsScreenshot)
        #expect(AskPurpose.answer.sendsScreenshot)
    }
}
