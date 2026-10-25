import Dispatch
import Foundation
import os

/// On-device speech-to-text of captured system audio with whisper.cpp.
///
/// Plug it into `AudioCaptureService(processor:)` and keep a strong reference (the service
/// holds the processor weakly). Blocks arrive on the audio consumer queue, are downmixed to
/// mono there and handed to this object's serial `queue`, so the consumer never waits.
/// `queue` resamples to 16 kHz and keeps the rolling window (`WhisperWindowing`); whisper
/// itself, which blocks for hundreds of milliseconds per run, runs on `inferenceQueue`.
/// At most one inference is outstanding while listening, so a slow Mac skips ahead to the
/// newest audio instead of building a backlog.
///
/// Privacy: audio is held in memory only (a window of at most ~15 s) and never written to
/// disk or sent anywhere. The transcript lives in memory only; nothing is persisted or logged.
///
/// Model handling: `start(model:language:)` asks the model store for the verified file.
/// No file → `.needsModel`. Otherwise the model loads on `inferenceQueue` (`.loadingModel`,
/// then `.listening`, or `.unavailable` if whisper rejects the file). Switching models
/// frees the old context first; a running inference is cut short via whisper's abort
/// callback whenever its result is no longer wanted.
///
/// `@unchecked Sendable` invariant: every mutable property under `// Queue-confined state`
/// is read and written only on `queue`, and `context` only on `inferenceQueue` (both
/// asserted with `dispatchPrecondition`). The only state touched from other threads is
/// `gate`, protected by its own lock; the remaining stored properties are immutable after
/// `init`.
public final class WhisperTranscriber: SystemAudioTranscribing, @unchecked Sendable {
    public let states: AsyncStream<TranscriptionState>
    public let transcripts: AsyncStream<Transcript>

    /// Blocks waiting on `queue` beyond this are dropped rather than queued without bound.
    private static let maxPendingBlocks = 64
    private static let whisperSampleRate = 16_000.0

    private let queue = DispatchQueue(label: "app.notchpilot.speech", qos: .userInitiated)
    private let inferenceQueue = DispatchQueue(label: "app.notchpilot.speech.inference", qos: .userInitiated)
    private let modelStore: any SpeechModelManaging
    private let windowConfiguration: WhisperWindowing.Configuration
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
    private var windowing: WhisperWindowing
    private var resampler: AudioResampler?
    /// Model and language of the current session (nil when off).
    private var session: (model: SpeechModel, language: String)?
    /// Model id loaded on `inferenceQueue`, as last reported back to `queue`.
    private var loadedModelID: String?
    /// Bumped per model load; only the newest load's result is applied.
    private var loadRequest = 0
    /// Model id of the load queued on `inferenceQueue` and not yet reported back, so a
    /// quick stop() + start() doesn't queue the same load twice.
    private var pendingLoadModelID: String?
    /// Language for the current utterance ("auto" is detected once per utterance).
    private var utteranceLanguage = UtteranceLanguage(requested: "auto")
    /// Bumped by start/stop/clear; results from an older session are discarded.
    private var generation = 0
    /// Bumped by clear; even a final pass from before it must not bring text back.
    private var clearEpoch = 0
    private var inferenceInFlight = false
    private var currentCancellation: InferenceCancellation?
    /// The pass started by `stop()`, so `shutdown()` can cut it short.
    private var finalPassCancellation: InferenceCancellation?
    /// Set while the stop() pass still owns the partial text on screen; a new session
    /// that starts first clears it, and the pass then leaves `partialText` alone.
    private var stopPassOwningPartial: InferenceCancellation?
    /// Incremented by every start and stop, so only the latest stop's idle unload runs.
    private var idleUnloadToken = 0
    /// True while macOS reports warning or critical memory pressure (updated on `queue`).
    private var memoryPressureElevated = false

    // Inference-queue-confined state.
    private var context: WhisperContext?

    /// Tracks memory pressure (warning, critical and back to normal); its handler runs on
    /// `queue`. Immutable after `init`, cancelled in `deinit`.
    private let memoryPressureSource: any DispatchSourceMemoryPressure

    // Memory budget (8 GB Macs with other apps open): the loaded model is the only large
    // allocation. It stays loaded while capturing, is freed `idleUnloadDelay` after capture
    // stops (starting again reloads it in about a second), and is freed at once on a memory
    // pressure warning while not capturing. While capturing it is kept: freeing it would
    // stop the transcript the person asked for.

    /// How long a model stays loaded after capture stops.
    static let defaultIdleUnloadDelay: Duration = .seconds(60)
    private let idleUnloadDelay: Duration

    public convenience init(modelStore: any SpeechModelManaging) {
        self.init(modelStore: modelStore, windowConfiguration: .default)
    }

    /// Injection point for tests (shorter steps, different thresholds, a short idle delay).
    init(modelStore: any SpeechModelManaging, windowConfiguration: WhisperWindowing.Configuration,
         idleUnloadDelay: Duration = WhisperTranscriber.defaultIdleUnloadDelay) {
        self.modelStore = modelStore
        self.windowConfiguration = windowConfiguration
        self.idleUnloadDelay = idleUnloadDelay
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        windowing = WhisperWindowing(configuration: windowConfiguration)
        (states, statesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (transcripts, transcriptsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        statesContinuation.yield(.off)
        transcriptsContinuation.yield(Transcript())
        memoryPressureSource.setEventHandler { [weak self] in
            guard let self else { return }
            memoryPressureDidChange(memoryPressureSource.data)
        }
        memoryPressureSource.activate()
    }

    deinit {
        // Pending work captures `self` strongly, so nothing is running here; the context
        // (if any) is freed with this object.
        memoryPressureSource.cancel()
        statesContinuation.finish()
        transcriptsContinuation.finish()
    }

    /// Starts (or switches) listening. Always re-checks the model file first: if it is gone
    /// (never downloaded, or deleted while in use) the session ends, the loaded model is
    /// freed and the state is `.needsModel`. Otherwise, the same model and language while
    /// listening or loading is a no-op.
    public func start(model: SpeechModel, language: String) {
        queue.async { [self] in
            idleUnloadToken += 1   // cancels a pending idle unload
            guard let fileURL = modelStore.installedFileURL(for: model) else {
                endSession()
                releasePartial()
                unloadModel()
                return setState(.needsModel)
            }
            if let session, session.model.id == model.id,
               state == .listening || state == .loadingModel {
                if session.language != language {
                    self.session = (model, language)
                    utteranceLanguage = UtteranceLanguage(requested: language)
                }
                return
            }
            // Switching (or restarting): keep what was heard, then start a fresh window.
            endSession()
            releasePartial()
            session = (model, language)
            utteranceLanguage = UtteranceLanguage(requested: language)
            if loadedModelID == model.id {
                gate.withLock { $0.listening = true }
                return setState(.listening)
            }
            setState(.loadingModel)
            // That load is already queued; its result opens the gate.
            if pendingLoadModelID == model.id { return }
            loadedModelID = nil
            pendingLoadModelID = model.id
            loadRequest += 1
            let request = loadRequest
            inferenceQueue.async { [self] in
                dispatchPrecondition(condition: .onQueue(inferenceQueue))
                context = nil   // free the old model before loading the next one
                let failure: WhisperContext.LoadError?
                do throws(WhisperContext.LoadError) {
                    context = try WhisperContext(model: model, fileURL: fileURL)
                    failure = nil
                } catch {
                    failure = error
                }
                let loaded = context != nil
                queue.async { [self] in
                    guard request == loadRequest else { return }   // a newer load or unload follows
                    pendingLoadModelID = nil
                    loadedModelID = loaded ? model.id : nil
                    // Stopped or switched while loading: keep the model, don't listen.
                    guard state == .loadingModel, session?.model.id == model.id else { return }
                    guard loaded else {
                        session = nil
                        let problem = failure == .damaged ? "file is damaged" : "couldn’t be loaded"
                        return setState(.unavailable("The \(model.displayName) model \(problem). Delete it in Settings › Speech and download it again."))
                    }
                    gate.withLock { $0.listening = true }
                    setState(.listening)
                }
            }
        }
    }

    /// Stops listening. If the window holds speech, it is transcribed one last time and
    /// that text is appended to the final text when the pass finishes; otherwise the
    /// partial text is committed now.
    public func stop() {
        gate.withLock { $0.listening = false }
        queue.async { [self] in
            let pending = windowing.hasSpeech && loadedModelID != nil ? windowing.samples : nil
            let speechSeconds = windowing.speechSeconds
            let language = utteranceLanguage.effective
            endSession()
            setState(.off)
            scheduleIdleUnload()
            guard let pending else { return commitPartial() }
            runFinalPass(pending, language: language, speechSeconds: speechSeconds)
        }
    }

    /// Forgets the transcript. If listening, transcription continues with a fresh window.
    public func clear() {
        queue.async { [self] in
            clearEpoch += 1
            generation += 1
            currentCancellation?.cancel()
            currentCancellation = nil
            inferenceInFlight = false
            stopPassOwningPartial = nil
            windowing.reset()
            utteranceLanguage.utteranceDidEnd()
            transcript = Transcript()
            transcriptsContinuation.yield(transcript)
        }
    }

    /// Stops listening and frees the loaded model before returning, cutting a running
    /// pass short. Call it before the process exits (the app does, in
    /// `applicationWillTerminate`): ggml's Metal backend frees its device in a C++ static
    /// destructor and aborts if a model is still loaded at that point. Blocks the caller
    /// only until whisper notices the abort. `start` afterwards loads the model again.
    public func shutdown() {
        gate.withLock { $0.listening = false }
        queue.sync {
            endSession()
            finalPassCancellation?.cancel()
            finalPassCancellation = nil
            loadRequest += 1   // a load still queued must not mark its model as loaded
            pendingLoadModelID = nil
            loadedModelID = nil
            setState(.off)
        }
        inferenceQueue.sync {
            context = nil
        }
    }

    /// Tests only: whether a whisper context is loaded, once queued work has run.
    var isModelLoaded: Bool {
        queue.sync {}
        return inferenceQueue.sync { context != nil }
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
        guard state == .listening, !mono.isEmpty else { return }
        if resampler?.inputRate != sampleRate {
            guard let made = AudioResampler(inputRate: sampleRate, outputRate: Self.whisperSampleRate) else {
                // Not retried per block: the state leaves `.listening`, so later blocks are ignored.
                endSession()
                commitPartial()
                setState(.failed("Unsupported audio format (\(Int(sampleRate)) Hz)."))
                return scheduleIdleUnload()
            }
            resampler = made
        }
        guard let resampler else { return }
        windowing.append(resampler.process(mono))
        pump()
    }

    /// Starts the next inference the window asks for, if none is running.
    private func pump() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard state == .listening, !inferenceInFlight, session != nil, let action = windowing.nextAction() else { return }
        let samples: [Float]
        let isFinal: Bool
        switch action {
        case .partial(let window): (samples, isFinal) = (window, false)
        case .final(let window): (samples, isFinal) = (window, true)
        }
        let cancellation = InferenceCancellation()
        currentCancellation = cancellation
        inferenceInFlight = true
        let current = generation
        let epoch = clearEpoch
        let speechSeconds = windowing.speechSeconds
        infer(samples, language: utteranceLanguage.effective, partial: !isFinal, cancellation: cancellation) { [self] result in
            guard current == generation else { return }
            inferenceInFlight = false
            currentCancellation = nil
            let cleaned = result.map { WhisperTextFilter.cleaned($0.text, speechSeconds: speechSeconds) }
            if epoch == clearEpoch {
                if isFinal {
                    // The final pass saw the whole utterance; if it produced nothing (or
                    // failed), the last partial is the best text there is.
                    if let cleaned, !cleaned.isEmpty { transcript.partialText = cleaned }
                    commitPartial()
                } else if let cleaned, cleaned != transcript.partialText {
                    transcript.partialText = cleaned
                    transcriptsContinuation.yield(transcript)
                }
            }
            if isFinal {
                windowing.didCommit(consumed: samples.count)
                utteranceLanguage.utteranceDidEnd()
            } else {
                utteranceLanguage.record(result?.language, speechSeconds: speechSeconds)
            }
            pump()   // audio that arrived meanwhile may already call for the next run
        }
    }

    /// The last pass after `stop()`. Not tied to a session: its text is appended straight
    /// to the final text even if listening restarts meanwhile (unless the transcript was
    /// cleared). The partial on screen is cleared only if no new session took it over.
    private func runFinalPass(_ samples: [Float], language: String, speechSeconds: Double) {
        dispatchPrecondition(condition: .onQueue(queue))
        let epoch = clearEpoch
        let fallback = transcript.partialText
        let cancellation = InferenceCancellation()
        finalPassCancellation = cancellation
        stopPassOwningPartial = cancellation
        infer(samples, language: language, partial: false, cancellation: cancellation) { [self] result in
            if finalPassCancellation === cancellation { finalPassCancellation = nil }
            let ownsPartial = stopPassOwningPartial === cancellation
            if ownsPartial { stopPassOwningPartial = nil }
            guard epoch == clearEpoch else { return }
            let cleaned = result.map { WhisperTextFilter.cleaned($0.text, speechSeconds: speechSeconds) } ?? ""
            transcript.finalText = SpeechText.appending(cleaned.isEmpty ? fallback : cleaned, to: transcript.finalText)
            if ownsPartial { transcript.partialText = "" }
            transcriptsContinuation.yield(transcript)
        }
    }

    /// Runs whisper on `inferenceQueue`, then calls `completion` on `queue` with the
    /// result, or nil if there is no model, whisper failed or the run was cancelled.
    private func infer(_ samples: [Float], language: String, partial: Bool, cancellation: InferenceCancellation,
                       completion: @escaping @Sendable (WhisperContext.Transcription?) -> Void) {
        inferenceQueue.async { [self] in
            dispatchPrecondition(condition: .onQueue(inferenceQueue))
            let result = context?.transcribe(samples, language: language, partial: partial,
                                             threads: WhisperContext.threadCount, cancellation: cancellation)
            queue.async { completion(result) }
        }
    }

    /// Hands the partial text on: to the pending stop() pass if one owns it (that pass
    /// appends its own, better text, so committing here would duplicate it), otherwise
    /// into the final text.
    private func releasePartial() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard stopPassOwningPartial != nil else { return commitPartial() }
        stopPassOwningPartial = nil
        if !transcript.partialText.isEmpty {
            transcript.partialText = ""
            transcriptsContinuation.yield(transcript)
        }
    }

    /// Frees the model `idleUnloadDelay` from now unless listening starts again first, or at
    /// once if memory pressure is already elevated (no new pressure event would arrive to
    /// do it). The unload is queued behind the stop pass on the inference queue, so that
    /// pass finishes.
    private func scheduleIdleUnload() {
        dispatchPrecondition(condition: .onQueue(queue))
        idleUnloadToken += 1
        if memoryPressureElevated { return unloadModel() }
        let token = idleUnloadToken
        let delay = idleUnloadDelay.components
        let nanoseconds = Int(delay.seconds) * 1_000_000_000 + Int(delay.attoseconds / 1_000_000_000)
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { [weak self] in
            guard let self, token == idleUnloadToken, session == nil else { return }
            unloadModel()
        }
    }

    /// Records the pressure level; on warning or critical, frees the model unless it is in
    /// use right now. During a session it is kept even at critical: freeing it would stop the
    /// transcript the person asked for (macOS compresses or swaps instead).
    private func memoryPressureDidChange(_ event: DispatchSource.MemoryPressureEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        memoryPressureElevated = !event.isDisjoint(with: [.warning, .critical])
        guard memoryPressureElevated, session == nil,
              loadedModelID != nil || pendingLoadModelID != nil else { return }
        unloadModel()
    }

    /// Frees the loaded model (after any pass already queued) and voids pending loads.
    private func unloadModel() {
        dispatchPrecondition(condition: .onQueue(queue))
        loadRequest += 1
        pendingLoadModelID = nil
        loadedModelID = nil
        inferenceQueue.async { [self] in
            context = nil
        }
    }

    /// Closes the gate and invalidates the running session's pending results.
    private func endSession() {
        dispatchPrecondition(condition: .onQueue(queue))
        gate.withLock { $0.listening = false }
        generation += 1
        currentCancellation?.cancel()
        currentCancellation = nil
        inferenceInFlight = false
        session = nil
        windowing.reset()
        utteranceLanguage.utteranceDidEnd()
        resampler = nil
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
}
