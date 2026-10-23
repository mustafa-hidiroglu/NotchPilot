import Accelerate
import Dispatch

/// What the UI needs to draw the meter and telemetry. Levels are linear amplitude (0…1+).
public struct LevelSnapshot: Sendable, Equatable {
    public var rms: Float
    public var peak: Float
    public var statistics: RingStatistics

    public init(rms: Float = 0, peak: Float = 0, statistics: RingStatistics = RingStatistics()) {
        self.rms = rms
        self.peak = peak
        self.statistics = statistics
    }

    /// RMS in dBFS, floored at -60.
    public var rmsDecibels: Float { rms > 0.001 ? max(-60, 20 * log10(rms)) : -60 }

    /// RMS mapped to 0…1 on a -60…0 dB scale, for drawing.
    public var normalizedLevel: Float { (rmsDecibels + 60) / 60 }
}

/// Hook for downstream processing (speech recognition, analysis, encoding…).
/// `process` runs on the consumer queue, never on the capture callback; keep it quick or
/// hand the samples to your own queue. `samples` is valid only for the duration of the call.
public protocol PCMBlockProcessor: AnyObject, Sendable {
    func process(_ samples: UnsafeBufferPointer<Float>, frames: Int, format: PCMFormat)
}

/// Drains the ring buffer on a utility queue with a non-blocking timer, measures levels and
/// forwards blocks downstream. Never touches UI: snapshots leave through a bounded
/// AsyncStream (newest value wins).
///
/// `@unchecked Sendable` invariant: every mutable property is read and written only on
/// `queue` (asserted with `dispatchPrecondition` in debug builds). `start()`/`stop()` hop onto
/// the queue themselves.
final class AudioPipelineConsumer: @unchecked Sendable {
    /// Called on `queue` when the producer reports rejected input (unsupported format).
    typealias RejectionHandler = @Sendable (PCMConverter.Rejection) -> Void

    private let queue = DispatchQueue(label: "app.notchpilot.audio-consumer", qos: .userInitiated)
    private let consumer: RingConsumer
    private let format: PCMFormat
    private let blockFrames: Int
    private let interval: Double
    private let publishEvery: Int
    private let block: UnsafeMutablePointer<Float>
    private let levels: AsyncStream<LevelSnapshot>.Continuation
    private let onRejection: RejectionHandler
    private weak var processor: PCMBlockProcessor?

    // Queue-confined state.
    private var timer: DispatchSourceTimer?
    private var ticksSincePublish = 0
    private var meterRMS: Float = 0
    private var meterPeak: Float = 0
    private var reportedRejections: UInt64 = 0

    init(consumer: consuming RingConsumer, format: PCMFormat, config: NotchPilotConfig,
         levels: AsyncStream<LevelSnapshot>.Continuation, processor: PCMBlockProcessor?,
         onRejection: @escaping RejectionHandler) {
        self.consumer = consumer
        self.format = format
        self.blockFrames = max(64, config.audio.consumerBlockFrames)
        self.interval = max(0.002, config.audio.consumerInterval)
        let refreshPeriod = 1 / max(1, config.animation.meterRefreshHz)
        self.publishEvery = max(1, Int((refreshPeriod / interval).rounded()))
        self.block = .allocate(capacity: blockFrames * format.channelCount)
        self.block.initialize(repeating: 0, count: blockFrames * format.channelCount)
        self.levels = levels
        self.processor = processor
        self.onRejection = onRejection
    }

    deinit {
        timer?.cancel()
        block.deallocate()
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    /// Stops the timer and drains whatever is still buffered. Completion runs on `queue`
    /// after the last tick, so the caller knows no further callbacks will happen.
    func stop() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                timer?.cancel()
                timer = nil
                drain(includingPartialBlock: true)
                levels.yield(LevelSnapshot(statistics: consumer.statistics))
                done.resume()
            }
        }
    }

    private func tick() {
        dispatchPrecondition(condition: .onQueue(queue))
        drain()
        checkRejections()

        ticksSincePublish += 1
        if ticksSincePublish >= publishEvery {
            ticksSincePublish = 0
            levels.yield(LevelSnapshot(rms: meterRMS, peak: meterPeak, statistics: consumer.statistics))
            // Ballistics: fall back gradually between publishes so the meter reads smoothly.
            meterRMS *= 0.6
            meterPeak *= 0.85
        }
    }

    /// While running, only full blocks are read: a partial block waits for the next tick, so
    /// polling never produces short reads (underruns). On stop, the remainder is flushed too,
    /// reading exactly what is available so it is not counted as an underrun.
    private func drain(includingPartialBlock: Bool = false) {
        while true {
            let available = consumer.availableFrames
            guard available >= blockFrames || (includingPartialBlock && available > 0) else { break }
            let frames = consumer.read(into: block, frames: min(available, blockFrames))
            guard frames > 0 else { break }
            let count = frames * format.channelCount
            var rms: Float = 0
            var peak: Float = 0
            vDSP_rmsqv(block, 1, &rms, vDSP_Length(count))
            vDSP_maxmgv(block, 1, &peak, vDSP_Length(count))
            meterRMS = max(meterRMS, rms)
            meterPeak = max(meterPeak, peak)
            processor?.process(UnsafeBufferPointer(start: block, count: count), frames: frames, format: format)
        }
    }

    /// Only structural format problems are reported (and stop capture). Transient ones —
    /// a single unreadable or oversized buffer — stay visible in the rejected-frame counter
    /// but do not end the session.
    private func checkRejections() {
        let stats = consumer.statistics
        guard stats.framesRejected > reportedRejections else { return }
        reportedRejections = stats.framesRejected
        if let reason = PCMConverter.Rejection(rawValue: stats.lastRejectReason), reason.isFatal {
            onRejection(reason)
        }
    }
}
