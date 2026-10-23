import AVFoundation
import Dispatch
import Foundation
import os
import Speech

/// On-device speech-to-text of captured system audio.
///
/// Plug it into `AudioCaptureService(processor:)` and keep a strong reference (the service
/// holds the processor weakly). Blocks arrive on the audio consumer queue, are downmixed to
/// mono there and handed to this object's own serial queue, so the consumer never waits on
/// the recognizer.
///
/// Privacy: `requiresOnDeviceRecognition` is always set, so audio never leaves the Mac. When
/// on-device recognition is not available the state is `.unavailable` — there is no server
/// fallback. Transcripts live in memory only; nothing is persisted or logged.
///
/// Recognition tasks end on their own (after about a minute, or on a long pause). Each final
/// result is appended to `Transcript.finalText` (capped at about 20k characters) and a fresh
/// request starts immediately.
///
/// `@unchecked Sendable` invariant: every mutable property below `// Queue-confined state` is
/// read and written only on `queue` (asserted with `dispatchPrecondition`). The recognizer
/// delivers results on an `OperationQueue` whose underlying queue is `queue`. The only state
/// touched from other threads is `gate`, which is protected by its own lock; the remaining
/// stored properties are immutable after `init`.
public final class SystemAudioTranscriber: PCMBlockProcessor, @unchecked Sendable {
    public let states: AsyncStream<TranscriptionState>
    public let transcripts: AsyncStream<Transcript>

    /// Why a recognizer cannot be used; `reason` is shown to the person.
    struct Unavailable: Error, Equatable {
        let reason: String
    }

    typealias AuthorizationCheck = @Sendable () -> SFSpeechRecognizerAuthorizationStatus
    typealias RecognizerFactory = @Sendable (Locale) -> Result<SFSpeechRecognizer, Unavailable>

    /// Blocks waiting on `queue` beyond this are dropped rather than queued without bound.
    private static let maxPendingBlocks = 64
    /// A task that fails sooner than this without producing text counts as a fast failure.
    private static let fastFailureWindow: Double = 2
    private static let maxFastFailures = 5
    /// Task rotation bounds (see `append`).
    private static let maxTaskDuration: Double = 55
    private static let maxPartialCharacters = 4_000

    private let queue = DispatchQueue(label: "app.notchpilot.speech", qos: .userInitiated)
    private let locale: Locale
    private let authorizationStatus: AuthorizationCheck
    private let makeRecognizer: RecognizerFactory
    private let statesContinuation: AsyncStream<TranscriptionState>.Continuation
    private let transcriptsContinuation: AsyncStream<Transcript>.Continuation

    /// Read on the audio consumer queue, written on `queue`.
    private struct Gate {
        var listening = false
        var pendingBlocks = 0
    }
    private let gate = OSAllocatedUnfairLock(initialState: Gate())

    // Queue-confined state.
    private var state: TranscriptionState = .off
    private var transcript = Transcript()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Incremented whenever a task is replaced, so late callbacks from old tasks are ignored.
    private var generation = 0
    private var taskStartedAt: DispatchTime = .now()
    private var taskProducedText = false
    private var fastFailures = 0
    private var audioFormat: AVAudioFormat?

    public convenience init(locale: Locale = .current) {
        self.init(locale: locale,
                  authorizationStatus: { SFSpeechRecognizer.authorizationStatus() },
                  makeRecognizer: SystemAudioTranscriber.onDeviceRecognizer)
    }

    /// Injection point for tests: lets them simulate permission and availability without
    /// touching the real recognizer.
    init(locale: Locale, authorizationStatus: @escaping AuthorizationCheck, makeRecognizer: @escaping RecognizerFactory) {
        self.locale = locale
        self.authorizationStatus = authorizationStatus
        self.makeRecognizer = makeRecognizer
        (states, statesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (transcripts, transcriptsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        statesContinuation.yield(.off)
        transcriptsContinuation.yield(Transcript())
    }

    deinit {
        task?.cancel()
        statesContinuation.finish()
        transcriptsContinuation.finish()
    }

    /// Asks for Speech Recognition permission. Returns true when granted.
    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Starts listening. Publishes `.needsPermission`, `.permissionDenied` or `.unavailable`
    /// instead when recognition cannot run. Calling it while listening does nothing.
    public func start() {
        queue.async { [self] in
            guard state != .listening else { return }
            switch authorizationStatus() {
            case .authorized:
                break
            case .notDetermined:
                return setState(.needsPermission)
            case .denied, .restricted:
                return setState(.permissionDenied)
            @unknown default:
                return setState(.permissionDenied)
            }
            if recognizer == nil {
                switch makeRecognizer(locale) {
                case .success(let made):
                    let delivery = OperationQueue()
                    delivery.maxConcurrentOperationCount = 1
                    delivery.underlyingQueue = queue
                    made.queue = delivery
                    recognizer = made
                case .failure(let unavailable):
                    return setState(.unavailable(unavailable.reason))
                }
            }
            fastFailures = 0
            beginTask()
            gate.withLock { $0.listening = true }
            setState(.listening)
        }
    }

    /// Stops listening. The utterance in progress is kept as final text.
    public func stop() {
        gate.withLock { $0.listening = false }
        queue.async { [self] in
            // Again on the queue: a `start()` queued just before this may have reopened it.
            gate.withLock { $0.listening = false }
            endTask()
            commitPartial()
            setState(.off)
        }
    }

    /// Forgets the transcript. If listening, recognition continues with a fresh task so the
    /// cleared text does not come back in the next partial result.
    public func clear() {
        queue.async { [self] in
            transcript = Transcript()
            if task != nil {
                endTask()
                beginTask()
            }
            transcriptsContinuation.yield(transcript)
        }
    }

    // MARK: - PCMBlockProcessor

    public func process(_ samples: UnsafeBufferPointer<Float>, frames: Int, format: PCMFormat) {
        let accepted = gate.withLock { gate -> Bool in
            guard gate.listening, gate.pendingBlocks < Self.maxPendingBlocks else { return false }
            gate.pendingBlocks += 1
            return true
        }
        guard accepted else { return }
        let mono = SpeechText.downmixToMono(samples, frames: frames, channels: format.channelCount)
        let sampleRate = format.sampleRate
        queue.async { [self] in
            gate.withLock { $0.pendingBlocks -= 1 }
            append(mono, sampleRate: sampleRate)
        }
    }

    // MARK: - Queue-confined

    private func append(_ mono: [Float], sampleRate: Double) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard request != nil, !mono.isEmpty else { return }
        if audioFormat?.sampleRate != sampleRate {
            let previous = audioFormat
            audioFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            // A request keeps the format of its first buffer; restart when the rate changes.
            if previous != nil {
                endTask()
                commitPartial()
                beginTask()
            }
        }
        // On-device tasks have no server time limit, so on continuous audio one task (its
        // buffered audio and ever-growing partial result) could live indefinitely. Rotate it
        // after a fixed duration or once the partial text gets long.
        let taskAge = Double(DispatchTime.now().uptimeNanoseconds - taskStartedAt.uptimeNanoseconds) / 1e9
        if taskAge > Self.maxTaskDuration || transcript.partialText.count > Self.maxPartialCharacters {
            endTask()
            commitPartial()
            beginTask()
        }
        guard let audioFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(mono.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        mono.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: mono.count) }
        buffer.frameLength = AVAudioFrameCount(mono.count)
        request?.append(buffer)
    }

    private func beginTask() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        generation += 1
        let current = generation
        taskStartedAt = .now()
        taskProducedText = false
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let update = result.map { (text: $0.bestTranscription.formattedString, isFinal: $0.isFinal) }
            self?.handle(update, failed: error != nil, generation: current)
        }
    }

    private func endTask() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation += 1
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func handle(_ update: (text: String, isFinal: Bool)?, failed: Bool, generation: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard generation == self.generation else { return }
        if let update {
            if !update.text.isEmpty {
                taskProducedText = true
                fastFailures = 0
            }
            transcript.partialText = update.text
            // A result delivered together with an error means the task is over, too.
            guard update.isFinal || failed else {
                transcriptsContinuation.yield(transcript)
                return
            }
            commitPartial()
            restartAfterTaskEnded()
        } else if failed {
            // Task ended without a final result (silence timeout, interruption…). Keep what
            // was heard and carry on, unless tasks keep failing straight away.
            let lifetime = Double(DispatchTime.now().uptimeNanoseconds - taskStartedAt.uptimeNanoseconds) / 1e9
            if lifetime >= Self.fastFailureWindow {
                fastFailures = 0          // only consecutive immediate failures count
            } else if !taskProducedText {
                fastFailures += 1
            }
            commitPartial()
            if fastFailures >= Self.maxFastFailures {
                gate.withLock { $0.listening = false }
                endTask()
                return setState(.failed("Speech recognition stopped responding."))
            }
            restartAfterTaskEnded()
        }
    }

    private func restartAfterTaskEnded() {
        dispatchPrecondition(condition: .onQueue(queue))
        endTask()
        if state == .listening { beginTask() }
    }

    private func commitPartial() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !transcript.partialText.isEmpty else { return }
        transcript.finalText = SpeechText.appending(transcript.partialText, to: transcript.finalText)
        transcript.partialText = ""
        transcriptsContinuation.yield(transcript)
    }

    private func setState(_ newState: TranscriptionState) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard newState != state else { return }
        state = newState
        statesContinuation.yield(newState)
    }

    // MARK: - Recognizer

    private static func onDeviceRecognizer(for locale: Locale) -> Result<SFSpeechRecognizer, Unavailable> {
        let language = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .failure(Unavailable(reason: "Speech recognition doesn’t support \(language)."))
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .failure(Unavailable(reason: "On-device recognition isn’t available for \(language) on this Mac."))
        }
        guard recognizer.isAvailable else {
            return .failure(Unavailable(reason: "Speech recognition is temporarily unavailable."))
        }
        return .success(recognizer)
    }
}
