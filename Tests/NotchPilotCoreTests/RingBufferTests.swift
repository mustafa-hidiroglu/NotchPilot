import Foundation
import NPRingBuffer
import Testing
@testable import NotchPilotCore

/// Stereo frame `i` is (i, -i) so order and channel placement are both checkable.
private func stereoFrames(_ range: Range<Int>) -> [Float] {
    range.flatMap { [Float($0), -Float($0)] }
}

@discardableResult
private func write(_ producer: borrowing RingProducer, _ samples: [Float]) -> Int {
    samples.withUnsafeBufferPointer { producer.write($0.baseAddress!, frames: samples.count / producer.channels) }
}

private func read(_ consumer: borrowing RingConsumer, frames: Int) -> [Float] {
    var out = [Float](repeating: .nan, count: frames * consumer.channels)
    let n = out.withUnsafeMutableBufferPointer { consumer.read(into: $0.baseAddress!, frames: frames) }
    return Array(out.prefix(n * consumer.channels))
}

private func isNil(_ ring: consuming RingBuffer?) -> Bool {
    switch consume ring {
    case .none: true
    case .some: false
    }
}

// RingProducer/RingConsumer are ~Copyable and cannot be captured by escaping closures
// directly. Each box is used by exactly one queue in the concurrency test (the producer box
// only by the producer block, the consumer box only by the consumer block, and the consumer
// box again only after both blocks finished), which is the same single-owner invariant the
// handles' own @unchecked Sendable relies on.
private final class ProducerBox: @unchecked Sendable {
    let producer: RingProducer
    init(_ producer: consuming RingProducer) { self.producer = producer }
}

private final class ConsumerBox: @unchecked Sendable {
    let consumer: RingConsumer
    var received: [Float] = []
    init(_ consumer: consuming RingConsumer) { self.consumer = consumer }
}

/// Splits the ring synchronously: partial consumption of the (non-frozen, cross-module)
/// `RingBuffer` is rejected inside an async function.
private func makeBoxes(_ ring: consuming RingBuffer) -> (ProducerBox, ConsumerBox) {
    let producer = ring.producer
    let consumer = ring.consumer
    return (ProducerBox(producer), ConsumerBox(consumer))
}

@Suite("RingBuffer wrapper")
struct RingBufferTests {

    @Test("capacity rounds up to the next power of two")
    func capacityRoundsToPowerOfTwo() throws {
        guard let ring = RingBuffer(minCapacityFrames: 100, channels: 2) else {
            Issue.record("ring allocation failed"); return
        }
        let producer = ring.producer
        let consumer = ring.consumer
        #expect(producer.capacityFrames == 128)
        #expect(consumer.capacityFrames == 128)
        #expect(producer.channels == 2)
        #expect(consumer.availableFrames == 0)
    }

    @Test("reading an empty ring returns 0 and counts one underrun")
    func emptyReadCountsUnderrun() {
        guard let ring = RingBuffer(minCapacityFrames: 8, channels: 2) else {
            Issue.record("ring allocation failed"); return
        }
        let consumer = ring.consumer
        #expect(read(consumer, frames: 4).isEmpty)
        #expect(consumer.statistics.underrunEvents == 1)
        #expect(consumer.statistics.framesRead == 0)
    }

    @Test("a zero-frame read is not counted as an underrun")
    func zeroFrameReadNotCounted() {
        guard let ring = RingBuffer(minCapacityFrames: 8, channels: 2) else {
            Issue.record("ring allocation failed"); return
        }
        let consumer = ring.consumer
        var sink: Float = 0
        #expect(consumer.read(into: &sink, frames: 0) == 0)
        #expect(consumer.statistics.underrunEvents == 0)
    }

    @Test("writing into a full ring drops the newest frames and counts overflow")
    func fullRingDropsNewest() {
        guard let ring = RingBuffer(minCapacityFrames: 8, channels: 2) else {
            Issue.record("ring allocation failed"); return
        }
        let producer = ring.producer
        let consumer = ring.consumer

        #expect(write(producer, stereoFrames(0..<6)) == 6)
        #expect(write(producer, stereoFrames(6..<12)) == 2)

        let stats = producer.statistics
        #expect(stats.framesWritten == 8)
        #expect(stats.framesDropped == 4)
        #expect(stats.overflowEvents == 1)
        // Old audio is kept; frames 8..<12 were the ones discarded.
        #expect(read(consumer, frames: 8) == stereoFrames(0..<8))
    }

    @Test("wraparound preserves frame order across many rounds")
    func wraparoundPreservesOrder() {
        guard let ring = RingBuffer(minCapacityFrames: 8, channels: 2) else {
            Issue.record("ring allocation failed"); return
        }
        let producer = ring.producer
        let consumer = ring.consumer

        // 5-frame chunks against an 8-frame ring land on every possible start offset.
        var next = 0
        for _ in 0..<200 {
            #expect(write(producer, stereoFrames(next..<next + 5)) == 5)
            #expect(read(consumer, frames: 5) == stereoFrames(next..<next + 5))
            next += 5
        }
        let stats = consumer.statistics
        #expect(stats.framesWritten == 1_000)
        #expect(stats.framesRead == 1_000)
        #expect(stats.framesDropped == 0)
        #expect(stats.underrunEvents == 0)
    }

    @Test("a partial read returns the available frames and counts an underrun")
    func partialReadCountsUnderrun() {
        guard let ring = RingBuffer(minCapacityFrames: 8, channels: 2) else {
            Issue.record("ring allocation failed"); return
        }
        let producer = ring.producer
        let consumer = ring.consumer
        write(producer, stereoFrames(0..<3))
        #expect(read(consumer, frames: 5) == stereoFrames(0..<3))
        #expect(consumer.statistics.underrunEvents == 1)
        #expect(consumer.statistics.framesRead == 3)
    }

    @Test("noteRejected records rejected frames and the latest reason")
    func noteRejectedRecordsReason() {
        guard let ring = RingBuffer(minCapacityFrames: 8, channels: 2) else {
            Issue.record("ring allocation failed"); return
        }
        let producer = ring.producer
        let consumer = ring.consumer
        producer.noteRejected(frames: 480, reason: PCMConverter.Rejection.notFloat32.rawValue)
        producer.noteRejected(frames: 20, reason: PCMConverter.Rejection.sampleRateMismatch.rawValue)

        let stats = consumer.statistics
        #expect(stats.framesRejected == 500)
        #expect(stats.lastRejectReason == PCMConverter.Rejection.sampleRateMismatch.rawValue)
        #expect(stats.framesWritten == 0)
    }

    @Test("invalid arguments produce no ring", arguments: [(0, 2), (8, 0), (-1, 2), (8, -1)])
    func invalidArgumentsReturnNil(capacity: Int, channels: Int) {
        let rejected = isNil(RingBuffer(minCapacityFrames: capacity, channels: channels))
        #expect(rejected)
    }

    @Test("a producer and consumer on two threads exchange frames in order without drops")
    func concurrentProducerConsumerPreservesOrder() async {
        guard let ring = RingBuffer(minCapacityFrames: 1_024, channels: 2) else {
            Issue.record("ring allocation failed"); return
        }
        let (producerBox, consumerBox) = makeBoxes(ring)

        let totalFrames = 200_000   // < 2^24, so every frame index is exact in Float
        let chunk = 300
        let group = DispatchGroup()

        DispatchQueue.global().async(group: group) {
            let samples = stereoFrames(0..<totalFrames)
            var sent = 0
            while sent < totalFrames {
                // Respect free space: never offer more than the ring can take.
                let free = np_ring_available_write(producerBox.producer.storage.ring)
                let n = min(chunk, totalFrames - sent, free)
                if n == 0 { sched_yield(); continue }
                let stored = samples.withUnsafeBufferPointer {
                    producerBox.producer.write($0.baseAddress! + sent * 2, frames: n)
                }
                sent += stored
            }
        }
        DispatchQueue.global().async(group: group) {
            var block = [Float](repeating: 0, count: 256 * 2)
            var received = [Float]()
            received.reserveCapacity(totalFrames * 2)
            while received.count < totalFrames * 2 {
                let want = min(256, consumerBox.consumer.availableFrames)
                if want == 0 { sched_yield(); continue }
                let n = block.withUnsafeMutableBufferPointer { consumerBox.consumer.read(into: $0.baseAddress!, frames: want) }
                received.append(contentsOf: block[0..<n * 2])
            }
            consumerBox.received = received
        }
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { continuation.resume() }
        }

        #expect(consumerBox.received == stereoFrames(0..<totalFrames))
        let stats = consumerBox.consumer.statistics
        #expect(stats.framesWritten == UInt64(totalFrames))
        #expect(stats.framesRead == UInt64(totalFrames))
        #expect(stats.framesDropped == 0)
        #expect(stats.overflowEvents == 0)
    }
}
