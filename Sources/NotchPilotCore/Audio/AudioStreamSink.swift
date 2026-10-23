import CoreMedia
import Dispatch
import Foundation
@preconcurrency import ScreenCaptureKit

/// SCStream output + delegate. The capture callback is the real-time producer:
/// convert → write to ring, nothing else.
///
/// `@unchecked Sendable` invariant: `converter` and `producer` are used only inside
/// `stream(_:didOutputSampleBuffer:of:)`, which ScreenCaptureKit invokes serially on
/// `sampleQueue` (the queue passed to `addStreamOutput`). All other stored properties are
/// immutable. The sink never references UI objects.
final class AudioStreamSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "app.notchpilot.audio-capture", qos: .userInteractive)

    private let converter: PCMConverter
    private let producer: RingProducer
    private let onStop: @Sendable (Error) -> Void

    init(producer: consuming RingProducer, converter: PCMConverter, onStop: @escaping @Sendable (Error) -> Void) {
        self.producer = producer
        self.converter = converter
        self.onStop = onStop
    }

    // MARK: Real-time path — no allocation, locks, logging, actor hops or UI work.

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer) else { return }
        switch converter.convert(sampleBuffer) {
        case .converted(let samples, let frames):
            producer.write(samples, frames: frames)
        case .rejected(let frames, let reason):
            // Reported asynchronously: the consumer polls the ring's reject counter.
            producer.noteRejected(frames: frames, reason: reason.rawValue)
        case .empty:
            break
        }
    }

    // MARK: Lifecycle (not real-time)

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }

    /// Resumes after every callback already queued on `sampleQueue` has finished.
    /// Used during teardown after the output has been removed. Non-blocking.
    func drainCallbacks() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sampleQueue.async { done.resume() }
        }
    }
}
