import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// Lifecycle state of system-audio capture.
public enum CaptureState: Sendable, Equatable {
    case idle
    case starting
    case running(PCMFormat)
    case stopping
    case failed(CaptureError)

    public var isActive: Bool {
        switch self {
        case .starting, .running, .stopping: true
        case .idle, .failed: false
        }
    }
}

/// Owns ScreenCaptureKit system-audio capture: permission checks, SCStream configuration,
/// the output sink, the ring buffer and its consumer, and orderly teardown.
///
/// Concurrency model
/// * Non-real-time state lives in this actor. `start()`/`stop()` are serialised through a
///   task chain so overlapping requests (e.g. Stop pressed while starting) run in order.
/// * The real-time path is `AudioStreamSink` on its own serial queue; it never hops onto
///   this actor. Format problems are reported through ring counters polled by the consumer.
/// * State and levels leave through bounded AsyncStreams consumed on the main actor.
///
/// Privacy: capture starts only when `start()` is called, is audio-only (no screen output is
/// registered, frames are never retained), excludes the microphone, and nothing is written
/// to disk or sent anywhere.
public actor AudioCaptureService {
    public nonisolated let states: AsyncStream<CaptureState>
    public nonisolated let levels: AsyncStream<LevelSnapshot>

    private let config: NotchPilotConfig
    private let statesContinuation: AsyncStream<CaptureState>.Continuation
    private let levelsContinuation: AsyncStream<LevelSnapshot>.Continuation
    private nonisolated(unsafe) weak var processor: PCMBlockProcessor?

    private var state: CaptureState = .idle
    private var session: Session?
    private var sessionID = 0
    private var operationTail: Task<Void, Never>?
    /// Set by `stop()` while a start is in flight. `performStart` checks it after every
    /// suspension point, so Stop takes effect immediately instead of after the stream has
    /// started (actor reentrancy lets `stop()` run while `performStart` is suspended).
    private var cancelPendingStart = false

    /// Everything that exists only while capturing. Released as a unit on teardown.
    private struct Session {
        let id: Int
        let stream: SCStream
        let sink: AudioStreamSink
        let consumer: AudioPipelineConsumer
    }

    public init(config: NotchPilotConfig = .default, processor: PCMBlockProcessor? = nil) {
        self.config = config
        self.processor = processor
        (states, statesContinuation) = AsyncStream.makeStream(of: CaptureState.self, bufferingPolicy: .bufferingNewest(8))
        (levels, levelsContinuation) = AsyncStream.makeStream(of: LevelSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        statesContinuation.yield(.idle)
    }

    /// Callers must `stop()` before releasing the service (the app does so on quit); a live
    /// session's SCStream is otherwise released without `stopCapture`.
    deinit {
        statesContinuation.finish()
        levelsContinuation.finish()
    }

    /// The published PCM format.
    public nonisolated var outputFormat: PCMFormat {
        PCMFormat(sampleRate: Double(config.audio.sampleRate), channelCount: config.audio.channelCount)
    }

    /// Whether Screen & System Audio Recording access is already granted. Never prompts.
    public nonisolated static var hasCapturePermission: Bool { CGPreflightScreenCaptureAccess() }

    public func start() async {
        await serialized { await $0.performStart() }
    }

    public func stop() async {
        if state == .starting { cancelPendingStart = true }
        await serialized { await $0.performStop(finalState: .idle) }
    }

    // MARK: - Serialisation

    @TaskLocal private static var isInsideOperation = false

    /// Runs `operation` after every previously queued one. Invariant: an operation must
    /// never call `serialized` (directly or via start/stop) — it would wait on a task queued
    /// behind itself forever. Event handlers enter from fresh tasks; debug builds assert it.
    private func serialized(_ operation: @escaping @Sendable (isolated AudioCaptureService) async -> Void) async {
        assert(!Self.isInsideOperation, "serialized() re-entered from inside an operation (deadlock)")
        let previous = operationTail
        let task = Task {
            await previous?.value
            await Self.$isInsideOperation.withValue(true) { await operation(self) }
        }
        operationTail = task
        await task.value
    }

    private func publish(_ newState: CaptureState) {
        state = newState
        statesContinuation.yield(newState)
    }

    // MARK: - Start

    private func performStart() async {
        guard !state.isActive else { return }
        cancelPendingStart = false
        publish(.starting)

        let display: SCDisplay
        do {
            display = try await Self.primaryDisplay()
            if cancelPendingStart { return publish(.idle) }
        } catch let error as CaptureError {
            return publish(.failed(error))
        } catch {
            return publish(.failed(.audioSourceUnavailable(error.localizedDescription)))
        }

        let format = outputFormat
        let audio = config.audio
        guard let ring = RingBuffer(minCapacityFrames: audio.ringCapacityFrames, channels: format.channelCount) else {
            return publish(.failed(.resourceAllocationFailed))
        }
        let producer = ring.producer
        let ringConsumer = ring.consumer

        sessionID += 1
        let id = sessionID
        let sink = AudioStreamSink(
            producer: producer,
            converter: PCMConverter(format: format, maxFrames: audio.maxFramesPerCallback),
            onStop: { [weak self] error in
                Task { await self?.streamDidStop(sessionID: id, error: error) }
            })
        let consumer = AudioPipelineConsumer(
            consumer: ringConsumer, format: format, config: config,
            levels: levelsContinuation, processor: processor,
            onRejection: { [weak self] reason in
                Task { await self?.formatRejected(sessionID: id, reason: reason) }
            })

        let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                              configuration: Self.streamConfiguration(for: format, audio: audio),
                              delegate: sink)
        do {
            // Audio output only. No `.screen` output is added, so video frames are never
            // delivered to (or retained by) NotchPilot.
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.sampleQueue)
        } catch {
            return publish(.failed(.streamFailed(error.localizedDescription)))
        }

        session = Session(id: id, stream: stream, sink: sink, consumer: consumer)
        consumer.start()
        do {
            try await Self.startCapture(stream)
            if cancelPendingStart {
                await teardown(stopStream: true)
                return publish(.idle)
            }
        } catch {
            let failure = Self.mapStreamError(error)
            await teardown(stopStream: false)
            return publish(.failed(failure))
        }
        publish(.running(format))
    }

    private static func streamConfiguration(for format: PCMFormat, audio: NotchPilotConfig.Audio) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = Int(format.sampleRate)
        configuration.channelCount = format.channelCount
        configuration.excludesCurrentProcessAudio = audio.excludesCurrentProcessAudio
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = false   // system audio only, never the microphone
        }
        // A display filter is required to obtain system audio. Keep the (unused) video side
        // as cheap as possible: 2×2 px, at most one frame per second, no cursor, tiny queue.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.queueDepth = 3
        return configuration
    }

    // MARK: - Stop / teardown

    private func performStop(finalState: CaptureState) async {
        guard session != nil else {
            if case .failed = state, finalState == .idle { publish(.idle) }
            return
        }
        publish(.stopping)
        let shutdownError = await teardown(stopStream: true)
        publish(shutdownError.map { .failed($0) } ?? finalState)
    }

    /// Orderly teardown: stop the stream → remove the output → wait for in-flight
    /// callbacks → stop the consumer → release everything. The ring memory is owned by the
    /// producer/consumer handles, so even a callback racing this sequence cannot touch freed
    /// memory.
    @discardableResult
    private func teardown(stopStream: Bool) async -> CaptureError? {
        guard let current = session else { return nil }
        session = nil
        var failure: CaptureError?
        if stopStream {
            do {
                try await Self.stopCapture(current.stream)
            } catch let error as NSError
                where error.domain == SCStreamErrorDomain && error.code == SCStreamError.attemptToStopStreamState.rawValue {
                // Already stopped by the system; nothing to report.
            } catch {
                failure = .shutdownFailed(error.localizedDescription)
            }
        }
        try? current.stream.removeStreamOutput(current.sink, type: .audio)
        await current.sink.drainCallbacks()
        await current.consumer.stop()
        return failure
    }

    // MARK: - Events from the capture side

    private func streamDidStop(sessionID id: Int, error: Error) async {
        await serialized { service in
            guard service.session?.id == id else { return }   // stale event from an old session
            let failure = Self.mapStreamError(error)
            await service.teardown(stopStream: false)
            service.publish(.failed(failure))
        }
    }

    private func formatRejected(sessionID id: Int, reason: PCMConverter.Rejection) async {
        await serialized { service in
            guard service.session?.id == id else { return }
            await service.performStop(finalState: .failed(.unsupportedFormat(reason.description)))
        }
    }

    // MARK: - ScreenCaptureKit helpers (completion-handler based so non-Sendable SCK objects
    // never cross an isolation boundary)

    private static func primaryDisplay() async throws -> SCDisplay {
        let content: SCShareableContent
        do {
            content = try await withCheckedThrowingContinuation { continuation in
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                    if let content { continuation.resume(returning: content) }
                    else { continuation.resume(throwing: error ?? CaptureError.audioSourceUnavailable("No shareable content")) }
                }
            }
        } catch {
            // Listing shareable content is what triggers (and requires) the TCC permission.
            if !CGPreflightScreenCaptureAccess() || Self.isUserDeclined(error) { throw CaptureError.permissionDenied }
            throw CaptureError.audioSourceUnavailable(error.localizedDescription)
        }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw CaptureError.audioSourceUnavailable("No display found")
        }
        return display
    }

    private static func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func stopCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.stopCapture { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func isUserDeclined(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.userDeclined.rawValue
    }

    static func mapStreamError(_ error: Error) -> CaptureError {
        if let error = error as? CaptureError { return error }
        if isUserDeclined(error) { return .permissionDenied }
        return .streamFailed(error.localizedDescription)
    }
}
