import Foundation

/// Accumulates streamed reply text and decides when the UI should show it, so the island
/// re-renders at most once per `interval` instead of once per token. The first delta is
/// shown at once (the reply area appears without delay); later ones are batched.
///
/// Usage: call `append` for every delta. If it returns text, show it. Otherwise schedule a
/// `flush` at `pendingDeadline` (unless one is already scheduled), so trailing text appears
/// even if no further delta arrives. Call `flush` once more when the stream finishes.
public struct ReplyTextCoalescer: Sendable {
    public typealias Instant = ContinuousClock.Instant

    public let interval: Duration
    /// Everything received so far.
    public private(set) var text = ""
    /// When the text received but not yet shown is due, or nil when the UI is up to date.
    public private(set) var pendingDeadline: Instant?
    private var lastPublished: Instant?

    /// 33 ms ≈ 30 updates per second.
    public init(interval: Duration = .milliseconds(33)) {
        self.interval = interval
    }

    /// Adds a delta. Returns the full text to show now, or nil to wait for `pendingDeadline`.
    public mutating func append(_ delta: String, at now: Instant) -> String? {
        guard !delta.isEmpty else { return nil }
        text += delta
        if let lastPublished, now < lastPublished + interval {
            if pendingDeadline == nil { pendingDeadline = lastPublished + interval }
            return nil
        }
        return publish(at: now)
    }

    /// Returns the full text if some of it hasn't been shown yet.
    public mutating func flush(at now: Instant) -> String? {
        guard pendingDeadline != nil else { return nil }
        return publish(at: now)
    }

    private mutating func publish(at now: Instant) -> String {
        lastPublished = now
        pendingDeadline = nil
        return text
    }
}
