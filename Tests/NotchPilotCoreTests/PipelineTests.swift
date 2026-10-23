import AudioToolbox
import CoreMedia
import Foundation
import Testing
@testable import NotchPilotCore

// Exercises the capture pipeline without ScreenCaptureKit: synthetic CMSampleBuffers go
// through PCMConverter.convert, and AudioPipelineConsumer drains a real C++ ring.

/// Builds a Float32 audio CMSampleBuffer whose data is copied from `channels` (planar input).
private func makeSampleBuffer(channels: [[Float]], sampleRate: Double = 48_000, interleaved: Bool) throws -> CMSampleBuffer {
    let channelCount = channels.count
    let frames = channels[0].count
    var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
    let bytesPerFrame = UInt32(MemoryLayout<Float>.size * (interleaved ? channelCount : 1))
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
        mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: UInt32(channelCount), mBitsPerChannel: 32, mReserved: 0)

    var format: CMAudioFormatDescription?
    try #require(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &format) == noErr)
    var sampleBuffer: CMSampleBuffer?
    try #require(CMAudioSampleBufferCreateWithPacketDescriptions(
        allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: try #require(format), sampleCount: frames,
        presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sampleBuffer) == noErr)
    let buffer = try #require(sampleBuffer)

    // Source data in the declared layout. CMSampleBufferSetDataBufferFromAudioBufferList copies it.
    var storage: [[Float]] = interleaved
        ? [(0..<frames).flatMap { frame in channels.map { $0[frame] } }]
        : channels
    let list = AudioBufferList.allocate(maximumBuffers: storage.count)
    defer { free(list.unsafeMutablePointer) }
    for index in storage.indices {
        storage[index].withUnsafeMutableBytes { bytes in
            list[index] = AudioBuffer(mNumberChannels: UInt32(interleaved ? channelCount : 1),
                                      mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
        }
    }
    // The pointers above stay valid: `storage` is not mutated again before the copy below.
    let status = storage.withUnsafeMutableBufferPointer { _ in
        CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                       flags: 0, bufferList: list.unsafePointer)
    }
    try #require(status == noErr)
    return buffer
}

@Suite("PCMConverter.convert with synthetic sample buffers")
struct ConvertTests {
    let format = PCMFormat(sampleRate: 48_000, channelCount: 2)

    @Test("planar stereo becomes interleaved stereo", arguments: [false, true])
    func stereo(interleavedSource: Bool) throws {
        let left: [Float] = (0..<256).map { Float($0) }
        let right = left.map { -$0 }
        let converter = PCMConverter(format: format, maxFrames: 1_024)
        let buffer = try makeSampleBuffer(channels: [left, right], interleaved: interleavedSource)

        guard case .converted(let samples, let frames) = converter.convert(buffer) else {
            Issue.record("expected conversion"); return
        }
        #expect(frames == 256)
        for frame in 0..<frames {
            #expect(samples[2 * frame] == left[frame])
            #expect(samples[2 * frame + 1] == right[frame])
        }
    }

    @Test("mono input is duplicated to both output channels")
    func mono() throws {
        let mono: [Float] = (0..<64).map { Float($0) / 64 }
        let converter = PCMConverter(format: format, maxFrames: 128)
        guard case .converted(let samples, let frames) = converter.convert(try makeSampleBuffer(channels: [mono], interleaved: false)) else {
            Issue.record("expected conversion"); return
        }
        #expect(frames == 64)
        for frame in 0..<frames {
            #expect(samples[2 * frame] == mono[frame] && samples[2 * frame + 1] == mono[frame])
        }
    }

    @Test("a different sample rate is rejected, not resampled")
    func sampleRateMismatch() throws {
        let converter = PCMConverter(format: format, maxFrames: 128)
        let buffer = try makeSampleBuffer(channels: [[0, 0], [0, 0]], sampleRate: 44_100, interleaved: false)
        guard case .rejected(let frames, let reason) = converter.convert(buffer) else {
            Issue.record("expected rejection"); return
        }
        #expect(frames == 2 && reason == .sampleRateMismatch)
    }

    @Test("buffers larger than the preallocated scratch are rejected")
    func tooLarge() throws {
        let converter = PCMConverter(format: format, maxFrames: 32)
        let samples = [Float](repeating: 0.25, count: 64)
        guard case .rejected(let frames, let reason) = converter.convert(try makeSampleBuffer(channels: [samples, samples], interleaved: false)) else {
            Issue.record("expected rejection"); return
        }
        #expect(frames == 64 && reason == .bufferTooLarge)
    }
}

/// Collects what the consumer forwards downstream. Called on the consumer queue only;
/// the lock lets the test thread read the totals.
private final class CollectingProcessor: PCMBlockProcessor, @unchecked Sendable {
    private let lock = NSLock()
    private var _frames = 0
    private var _maxSample: Float = 0
    var frames: Int { lock.withLock { _frames } }
    var maxSample: Float { lock.withLock { _maxSample } }

    func process(_ samples: UnsafeBufferPointer<Float>, frames: Int, format: PCMFormat) {
        let peak = samples.map(abs).max() ?? 0
        lock.withLock {
            _frames += frames
            _maxSample = max(_maxSample, peak)
        }
    }
}

private final class RejectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _reasons: [PCMConverter.Rejection] = []
    var reasons: [PCMConverter.Rejection] { lock.withLock { _reasons } }
    func record(_ reason: PCMConverter.Rejection) { lock.withLock { _reasons.append(reason) } }
}

@Suite("AudioPipelineConsumer")
struct ConsumerTests {
    private static func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("transient rejections are counted but not reported as fatal")
    func transientRejectionIsNotFatal() async throws {
        var config = NotchPilotConfig()
        config.audio.consumerInterval = 0.005
        guard let ring = RingBuffer(minCapacityFrames: 1_024, channels: 2) else {
            Issue.record("ring allocation failed"); return
        }
        let producer = ring.producer
        let ringConsumer = ring.consumer
        let (_, continuation) = AsyncStream.makeStream(of: LevelSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let rejections = RejectionRecorder()
        let consumer = AudioPipelineConsumer(consumer: ringConsumer, format: PCMFormat(sampleRate: 48_000, channelCount: 2),
                                             config: config, levels: continuation, processor: nil,
                                             onRejection: { rejections.record($0) })
        producer.noteRejected(frames: 512, reason: PCMConverter.Rejection.copyFailed.rawValue)
        consumer.start()
        try await Task.sleep(for: .milliseconds(100))
        await consumer.stop()
        #expect(rejections.reasons.isEmpty)
        #expect(producer.statistics.framesRejected == 512)
    }

    @Test("drains full blocks downstream, publishes levels and reports rejections")
    func drainsAndReports() async throws {
        var config = NotchPilotConfig()
        config.audio.consumerBlockFrames = 256
        config.audio.consumerInterval = 0.005
        let format = PCMFormat(sampleRate: 48_000, channelCount: 2)
        // #require can't take a ~Copyable optional, so unwrap by hand.
        guard let ring = RingBuffer(minCapacityFrames: 4_096, channels: 2) else {
            Issue.record("ring allocation failed"); return
        }
        let producer = ring.producer
        let ringConsumer = ring.consumer

        let (levels, continuation) = AsyncStream.makeStream(of: LevelSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let processor = CollectingProcessor()
        let rejections = RejectionRecorder()
        let consumer = AudioPipelineConsumer(consumer: ringConsumer, format: format, config: config,
                                             levels: continuation, processor: processor,
                                             onRejection: { rejections.record($0) })

        // 1024 frames = 4 full blocks, plus 100 frames that never complete a block.
        let block = [Float](repeating: 0.5, count: 1_124 * 2)
        block.withUnsafeBufferPointer { _ = producer.write($0.baseAddress!, frames: 1_124) }
        producer.noteRejected(frames: 10, reason: PCMConverter.Rejection.sampleRateMismatch.rawValue)

        consumer.start()
        #expect(await Self.waitUntil { processor.frames == 1_024 })
        #expect(await Self.waitUntil { rejections.reasons == [.sampleRateMismatch] })
        await consumer.stop()

        #expect(processor.frames == 1_124)         // stop() flushes the partial block
        #expect(processor.maxSample == 0.5)
        continuation.finish()
        var last: LevelSnapshot?
        for await snapshot in levels { last = snapshot }
        let stats = try #require(last).statistics
        #expect(stats.framesRead == 1_124)
        #expect(stats.underrunEvents == 0)         // full blocks while running, exact remainder on stop
        #expect(stats.framesRejected == 10)
    }
}
