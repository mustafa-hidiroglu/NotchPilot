import NPRingBuffer

/// Snapshot of the C++ ring's cumulative counters.
public struct RingStatistics: Sendable, Equatable {
    public var framesWritten: UInt64 = 0
    public var framesRead: UInt64 = 0
    public var framesDropped: UInt64 = 0
    public var overflowEvents: UInt64 = 0
    public var underrunEvents: UInt64 = 0
    public var framesRejected: UInt64 = 0
    /// Producer-defined code of the latest rejection (see `PCMConverter.Rejection`), 0 = none.
    public var lastRejectReason: UInt32 = 0
    public init() {}
}

// MARK: - Audited unsafe boundary
//
// This file is the only place Swift touches the C++ ring. Invariants:
//
//  1. `RingStorage` owns the NPRing and destroys it in `deinit`. Producer and consumer
//     handles hold strong references, so the C++ object outlives every possible caller,
//     including a late capture callback that races teardown: no use-after-free.
//  2. `RingProducer` and `RingConsumer` are `~Copyable`. `RingBuffer.make` creates exactly
//     one of each and they cannot be duplicated, which enforces the single-producer /
//     single-consumer contract in the type system. (Debug builds additionally assert it
//     inside C++.)
//  3. The handles are `@unchecked Sendable` because moving a handle to the thread/queue
//     that will use it is the whole point; the C++ side synchronises through
//     acquire/release atomics, and a ~Copyable handle can only be used by one owner.
//  4. `RingStorage` is `@unchecked Sendable` because its only mutable state lives behind
//     the C++ atomics; its Swift stored properties are immutable.

final class RingStorage: @unchecked Sendable {
    let ring: OpaquePointer
    let channels: Int
    let capacityFrames: Int

    init?(minCapacityFrames: Int, channels: Int) {
        guard minCapacityFrames > 0, channels > 0,
              let ring = np_ring_create(minCapacityFrames, UInt32(channels)) else { return nil }
        self.ring = ring
        self.channels = Int(np_ring_channels(ring))
        self.capacityFrames = np_ring_capacity_frames(ring)
    }

    deinit { np_ring_destroy(ring) }

    var statistics: RingStatistics {
        let s = np_ring_stats(ring)
        var out = RingStatistics()
        out.framesWritten = s.framesWritten
        out.framesRead = s.framesRead
        out.framesDropped = s.framesDropped
        out.overflowEvents = s.overflowEvents
        out.underrunEvents = s.underrunEvents
        out.framesRejected = s.framesRejected
        out.lastRejectReason = s.lastRejectReason
        return out
    }
}

/// The unique producer/consumer pair of one ring. Split it by consuming its fields:
/// `let producer = ring.producer; let consumer = ring.consumer`.
/// `@frozen` so that split also compiles in other modules: Swift only allows partial
/// consumption of a non-copyable struct whose layout is visible to the client.
@frozen
public struct RingBuffer: ~Copyable {
    public var producer: RingProducer
    public var consumer: RingConsumer

    /// Allocates a ring and its handles. Allocates: call outside the real-time path.
    /// Returns nil for invalid arguments or if memory could not be reserved.
    public init?(minCapacityFrames: Int, channels: Int) {
        guard let storage = RingStorage(minCapacityFrames: minCapacityFrames, channels: channels) else {
            return nil
        }
        producer = RingProducer(storage: storage)
        consumer = RingConsumer(storage: storage)
    }
}

/// Write side of the ring. No allocation or locks: one C++ call. (Reaching the storage
/// through a class reference may emit a retain/release.)
public struct RingProducer: ~Copyable, @unchecked Sendable {
    let storage: RingStorage

    public var channels: Int { storage.channels }
    public var capacityFrames: Int { storage.capacityFrames }

    /// Writes `frames` interleaved frames. Returns frames stored; the remainder is dropped
    /// and counted as overflow.
    @discardableResult
    public func write(_ interleaved: UnsafePointer<Float>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        return np_ring_write(storage.ring, interleaved, frames)
    }

    /// Records input frames discarded before reaching the ring (e.g. unsupported format)
    /// with a non-zero reason code that the consumer reads back from `statistics`.
    public func noteRejected(frames: Int, reason: UInt32) {
        np_ring_note_rejected(storage.ring, max(frames, 0), reason)
    }

    public var statistics: RingStatistics { storage.statistics }
}

/// Read side of the ring.
public struct RingConsumer: ~Copyable, @unchecked Sendable {
    let storage: RingStorage

    public var channels: Int { storage.channels }
    public var capacityFrames: Int { storage.capacityFrames }
    public var availableFrames: Int { np_ring_available_read(storage.ring) }

    /// Reads up to `frames` interleaved frames into `destination` (which must hold
    /// `frames * channels` samples). Returns frames copied; a short read counts as underrun.
    public func read(into destination: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        return np_ring_read(storage.ring, destination, frames)
    }

    public var statistics: RingStatistics { storage.statistics }
}
