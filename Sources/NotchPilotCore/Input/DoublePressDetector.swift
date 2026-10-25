import Foundation

/// Tells a quick second press of the Ask shortcut from a separate one. Pure and clock-free:
/// the caller passes the time of each press (`ContinuousClock.now` in the app, fixed
/// instants in tests).
public struct DoublePressDetector: Sendable {
    public typealias Instant = ContinuousClock.Instant

    public enum Press: Sendable, Equatable {
        /// A press on its own (or the first of a possible pair).
        case single
        /// A press that follows the previous one within `interval`.
        case double
    }

    /// The system double-click interval (`NSEvent.doubleClickInterval`, set in System
    /// Settings) clamped to 0.2–0.5 s: shorter is hard to hit on a key, longer makes a
    /// deliberate "open, then close" feel like a double press.
    public static func interval(systemDoubleClickInterval seconds: TimeInterval) -> Duration {
        let clamped = seconds.isFinite ? min(max(seconds, 0.2), 0.5) : 0.5
        return .milliseconds(Int((clamped * 1_000).rounded()))
    }

    public var interval: Duration
    private var lastSingle: Instant?

    public init(interval: Duration) {
        self.interval = interval
    }

    /// Classifies a press. A double press consumes the pair, so a third quick press is a
    /// new single press rather than another double.
    public mutating func register(at now: Instant) -> Press {
        if let lastSingle, now >= lastSingle, now - lastSingle <= interval {
            self.lastSingle = nil
            return .double
        }
        lastSingle = now
        return .single
    }

    public mutating func reset() {
        lastSingle = nil
    }
}

/// What a press of the Ask shortcut does to the island (README › Ask shortcut):
///  * island not open for typing → open it at once (no waiting to see whether a second
///    press follows); `modeForOpening` picks the mode;
///  * a quick second press right after that opening press → switch the open island to the
///    other mode (when "press twice" is on);
///  * any other press while it is open → close it.
public struct QuickAskPressRouter: Sendable {
    public enum Action: Sendable, Equatable {
        case open
        /// Switch to the other mode of the one currently shown.
        case switchMode
        case close
    }

    private var detector: DoublePressDetector
    /// The previous press opened the island, so a quick press now is the second of a pair.
    private var previousPressOpened = false

    public init(interval: Duration) {
        detector = DoublePressDetector(interval: interval)
    }

    public var interval: Duration {
        get { detector.interval }
        set { detector.interval = newValue }
    }

    /// - Parameters:
    ///   - isOpen: the island is expanded and taking keystrokes (a quick Ask is open).
    ///   - doublePressEnabled: `AssistantSettings.askHotKeyDoublePress`.
    public mutating func press(at now: DoublePressDetector.Instant, isOpen: Bool, doublePressEnabled: Bool) -> Action {
        let kind = detector.register(at: now)
        if kind == .double, previousPressOpened, isOpen, doublePressEnabled {
            previousPressOpened = false
            return .switchMode
        }
        if isOpen {
            previousPressOpened = false
            return .close
        }
        previousPressOpened = true
        return .open
    }

    /// Forgets earlier presses; called whenever the island collapses, by any path, so a
    /// press after that always starts fresh.
    public mutating func reset() {
        detector.reset()
        previousPressOpened = false
    }

    /// The mode a shortcut press (or the status menu's Ask item) opens the island in:
    ///  * already expanded (just not taking keystrokes) → keep the mode on screen;
    ///  * a chat reply arrived while collapsed → Chat, so it is seen;
    ///  * otherwise → the "one press opens" mode.
    public static func modeForOpening(singlePress: AskMode, current: AskMode, isExpanded: Bool,
                                      hasUnseenChatReply: Bool) -> AskMode {
        if isExpanded { return current }
        if hasUnseenChatReply { return .chat }
        return singlePress
    }
}
