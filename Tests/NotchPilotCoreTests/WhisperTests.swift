import AVFoundation
import CryptoKit
import Foundation
import os
import Testing
@testable import NotchPilotCore

// MARK: - Helpers

private func sine(frequency: Double, amplitude: Float, sampleRate: Double, seconds: Double) -> [Float] {
    let count = Int(sampleRate * seconds)
    return (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

private func rms(_ samples: some Collection<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

/// Returns the first element of `stream` matching `predicate`, or nil after `timeout`.
private func first<T: Sendable>(_ stream: AsyncStream<T>, timeout: Duration = .seconds(10),
                                where predicate: @escaping @Sendable (T) -> Bool) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream where predicate(value) { return value }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

// MARK: - Resampler

@Suite("AudioResampler")
struct AudioResamplerTests {

    @Test("48 kHz to 16 kHz keeps a third of the samples over a stream of blocks")
    func lengthRatio() throws {
        let resampler = try #require(AudioResampler(inputRate: 48_000, outputRate: 16_000))
        var produced = 0
        for _ in 0..<100 { produced += resampler.process([Float](repeating: 0, count: 480)).count }
        // 48 000 input samples → 16 000 output, minus a little filter latency.
        #expect(produced <= 16_000)
        #expect(produced >= 15_800)
    }

    @Test("44.1 kHz input is supported too")
    func otherRate() throws {
        let resampler = try #require(AudioResampler(inputRate: 44_100, outputRate: 16_000))
        var produced = 0
        for _ in 0..<100 { produced += resampler.process([Float](repeating: 0, count: 441)).count }
        #expect(abs(produced - 16_000) < 200)
    }

    @Test("a constant level passes through unchanged once the filter has settled")
    func preservesDC() throws {
        let resampler = try #require(AudioResampler(inputRate: 48_000, outputRate: 16_000))
        var output: [Float] = []
        for _ in 0..<20 { output += resampler.process([Float](repeating: 0.5, count: 480)) }
        let settled = output.dropFirst(output.count / 2)
        for sample in settled { #expect(abs(sample - 0.5) < 0.01) }
    }

    @Test("a 440 Hz tone keeps its level and frequency")
    func preservesSine() throws {
        let resampler = try #require(AudioResampler(inputRate: 48_000, outputRate: 16_000))
        let input = sine(frequency: 440, amplitude: 0.8, sampleRate: 48_000, seconds: 1)
        var output: [Float] = []
        for start in stride(from: 0, to: input.count, by: 480) {
            output += resampler.process(Array(input[start..<min(start + 480, input.count)]))
        }
        let settled = Array(output.dropFirst(1_600))   // skip 0.1 s of filter warm-up
        #expect(abs(rms(settled) - 0.8 / Float(2).squareRoot()) < 0.02)
        // Rising zero crossings per second ≈ frequency.
        var crossings = 0
        for index in 1..<settled.count where settled[index - 1] < 0 && settled[index] >= 0 { crossings += 1 }
        let seconds = Double(settled.count) / 16_000
        #expect(abs(Double(crossings) / seconds - 440) < 5)
    }

    @Test("equal rates pass samples through; invalid rates are rejected")
    func edgeCases() throws {
        let passthrough = try #require(AudioResampler(inputRate: 16_000, outputRate: 16_000))
        #expect(passthrough.process([0.1, 0.2]) == [0.1, 0.2])
        #expect(passthrough.process([]).isEmpty)
        #expect(AudioResampler(inputRate: 0, outputRate: 16_000) == nil)
    }
}

// MARK: - Windowing

@Suite("WhisperWindowing")
struct WhisperWindowingTests {
    private let configuration = WhisperWindowing.Configuration(step: 1.0)

    private func speech(_ seconds: Double) -> [Float] {
        sine(frequency: 220, amplitude: 0.1, sampleRate: 16_000, seconds: seconds)
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(16_000 * seconds))
    }

    @Test("silence is never transcribed and is trimmed to the pre-roll")
    func silenceOnly() {
        var windowing = WhisperWindowing(configuration: configuration)
        windowing.append(silence(5))
        #expect(windowing.nextAction() == nil)
        #expect(!windowing.hasSpeech)
        #expect(windowing.samples.count == configuration.preRollSamples)
    }

    @Test("speech asks for a partial pass every step")
    func partialEveryStep() {
        var windowing = WhisperWindowing(configuration: configuration)
        windowing.append(speech(0.5))
        #expect(windowing.nextAction() == nil)
        windowing.append(speech(0.6))
        guard case .partial(let samples) = windowing.nextAction() else {
            Issue.record("expected a partial pass")
            return
        }
        #expect(samples.count == windowing.samples.count)
        #expect(windowing.nextAction() == nil)   // the step restarts after each pass
        windowing.append(speech(1.0))
        guard case .partial = windowing.nextAction() else {
            Issue.record("expected a second partial pass")
            return
        }
    }

    @Test("a pause after speech completes the utterance")
    func pauseCommits() {
        var windowing = WhisperWindowing(configuration: .init(step: 100))
        windowing.append(speech(0.5))
        windowing.append(silence(0.5))
        #expect(windowing.nextAction() == nil)   // 0.5 s of quiet is not a pause yet
        windowing.append(silence(0.3))
        guard case .final(let samples) = windowing.nextAction() else {
            Issue.record("expected a final pass")
            return
        }
        #expect(samples.count == 16_000 * 13 / 10)
    }

    @Test("a window at its maximum length is committed even mid-speech")
    func maxWindowCommits() {
        var windowing = WhisperWindowing(configuration: .init(step: 100, maxWindow: 3))
        windowing.append(speech(2.9))
        #expect(windowing.nextAction() == nil)
        windowing.append(speech(0.2))
        guard case .final = windowing.nextAction() else {
            Issue.record("expected a final pass")
            return
        }
    }

    @Test("committing keeps audio that arrived during the final pass")
    func commitKeepsNewAudio() {
        var windowing = WhisperWindowing(configuration: configuration)
        windowing.append(speech(0.5))
        windowing.append(silence(0.8))
        guard case .final(let samples) = windowing.nextAction() else {
            Issue.record("expected a final pass")
            return
        }
        windowing.append(speech(0.4))     // arrives while whisper runs
        windowing.didCommit(consumed: samples.count)
        #expect(windowing.samples.count == 6_400)
        #expect(windowing.hasSpeech)
        #expect(abs(windowing.speechSeconds - 0.4) < 0.01)
    }

    @Test("audio held while a pass runs is capped at twice the window; the next pass covers one window")
    func hardCap() {
        var windowing = WhisperWindowing(configuration: .init(step: 100, maxWindow: 3))
        windowing.append(speech(3.2))
        guard case .final(let snapshot) = windowing.nextAction() else {
            Issue.record("expected a final pass")
            return
        }
        #expect(snapshot.count <= 3 * 16_000)
        // A slow pass: 20 s more arrive before it finishes.
        for _ in 0..<200 {
            windowing.append(speech(0.1))
            #expect(windowing.samples.count <= windowing.hardLimitSamples)
        }
        windowing.didCommit(consumed: snapshot.count)
        #expect(windowing.samples.count <= windowing.hardLimitSamples)
        guard case .final(let next) = windowing.nextAction() else {
            Issue.record("expected the next final pass")
            return
        }
        #expect(next.count <= 3 * 16_000)
        #expect(windowing.hasSpeech)
    }

    @Test("commit after a capped pass drops only what is still there")
    func commitAfterCap() {
        var windowing = WhisperWindowing(configuration: .init(step: 100, maxWindow: 2))
        windowing.append(speech(2.0))
        guard case .final(let snapshot) = windowing.nextAction() else {
            Issue.record("expected a final pass")
            return
        }
        windowing.append(speech(3.0))   // 5 s held → capped at 4 s, 1 s of the snapshot gone
        #expect(windowing.samples.count == windowing.hardLimitSamples)
        windowing.didCommit(consumed: snapshot.count)
        #expect(windowing.samples.count == 3 * 16_000)   // exactly the audio that arrived later
    }

    @Test("reset forgets everything")
    func reset() {
        var windowing = WhisperWindowing(configuration: configuration)
        windowing.append(speech(2))
        windowing.reset()
        #expect(windowing.samples.isEmpty)
        #expect(!windowing.hasSpeech)
        #expect(windowing.nextAction() == nil)
    }

    @Test("speech is told from quiet by RMS")
    func rmsThreshold() {
        #expect(WhisperWindowing.rms([0.5, -0.5, 0.5, -0.5][...]) == 0.5)
        #expect(WhisperWindowing.rms([][...]) == 0)
        var windowing = WhisperWindowing(configuration: configuration)
        windowing.append(sine(frequency: 220, amplitude: 0.002, sampleRate: 16_000, seconds: 2))   // ≈ −57 dBFS hiss
        #expect(!windowing.hasSpeech)
    }
}

// MARK: - Utterance language

@Suite("UtteranceLanguage")
struct UtteranceLanguageTests {

    @Test("auto detects once per utterance, then passes the code explicitly")
    func autoDetectsOnce() {
        var language = UtteranceLanguage(requested: "auto")
        #expect(language.effective == "auto")
        language.record("de", speechSeconds: 0.5)        // too little speech to trust
        #expect(language.effective == "auto")
        language.record("de", speechSeconds: 2)
        #expect(language.effective == "de")
        language.record("fr", speechSeconds: 5)          // no flicker within the utterance
        #expect(language.effective == "de")
        language.utteranceDidEnd()
        #expect(language.effective == "auto")
        language.record(nil, speechSeconds: 5)
        #expect(language.effective == "auto")
    }

    @Test("an explicit language is always passed as is")
    func explicitLanguage() {
        var language = UtteranceLanguage(requested: "en")
        language.record("de", speechSeconds: 5)
        #expect(language.effective == "en")
        language.utteranceDidEnd()
        #expect(language.effective == "en")
    }
}

// MARK: - Hallucination filter

@Suite("WhisperTextFilter")
struct WhisperTextFilterTests {

    @Test("annotation-only output is dropped", arguments: ["[BLANK_AUDIO]", "(music)", "[Music]", " [ Silence ] ", "*laughs*", "♪♪", "...", ""])
    func annotationsDropped(_ raw: String) {
        #expect(WhisperTextFilter.cleaned(raw, speechSeconds: 5) == "")
    }

    @Test("annotations inside real speech are removed")
    func inlineAnnotations() {
        #expect(WhisperTextFilter.cleaned(" Hello [Music] world (applause) again.", speechSeconds: 5) == "Hello world again.")
    }

    @Test("'Thank you.' on near-silence is a hallucination; with real speech it is kept")
    func thankYou() {
        #expect(WhisperTextFilter.cleaned(" Thank you.", speechSeconds: 0.3) == "")
        #expect(WhisperTextFilter.cleaned("Thanks for watching!", speechSeconds: 0.5) == "")
        #expect(WhisperTextFilter.cleaned(" Thank you.", speechSeconds: 3) == "Thank you.")
        #expect(WhisperTextFilter.cleaned("Thank you for the update.", speechSeconds: 0.3) == "Thank you for the update.")
    }

    @Test("ordinary text passes through trimmed")
    func passthrough() {
        #expect(WhisperTextFilter.cleaned("  Hello world, this is a test. ", speechSeconds: 2) == "Hello world, this is a test.")
    }
}

// MARK: - Model store

/// Serves model downloads for `SpeechModelStoreTests`, keyed by file name so tests can run
/// in parallel. Bodies are sent in paced chunks so progress is observable.
private final class ModelURLProtocol: URLProtocol, @unchecked Sendable {
    struct Route: Sendable {
        var status = 200
        var body: Data
        /// Stop after the first chunk and never finish (for cancellation).
        var stall = false
    }

    private static let routes = OSAllocatedUnfairLock(initialState: [String: Route]())
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    static func serve(_ fileName: String, _ route: Route) {
        routes.withLock { $0[fileName] = route }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { stopped.withLock { $0 = true } }

    override func startLoading() {
        guard let url = request.url, let route = Self.routes.withLock({ $0[url.lastPathComponent] }),
              let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": "\(route.body.count)"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunkSize = max(1, route.body.count / 8)
        let chunks = stride(from: 0, to: route.body.count, by: chunkSize).map {
            route.body.subdata(in: $0..<min($0 + chunkSize, route.body.count))
        }
        deliver(chunks[...], route: route)
    }

    private func deliver(_ chunks: ArraySlice<Data>, route: Route) {
        guard !stopped.withLock({ $0 }) else { return }
        guard let chunk = chunks.first else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didLoad: chunk)
        if route.stall { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { [self] in
            deliver(chunks.dropFirst(), route: route)
        }
    }
}

@Suite("SpeechModelStore")
struct SpeechModelStoreTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "NotchPilotModelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func makeModel(body: Data, sha256: String? = nil) -> SpeechModel {
        let digest = sha256 ?? SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return SpeechModel(id: "test-\(UUID().uuidString)", displayName: "Test", summary: "",
                           fileName: "ggml-test-\(UUID().uuidString).bin",
                           sizeBytes: Int64(body.count), sha256: digest)
    }

    private func makeStore(_ models: [SpeechModel]) -> SpeechModelStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelURLProtocol.self]
        return SpeechModelStore(directory: directory, configuration: configuration, catalog: models)
    }

    private func randomBody(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private func directoryContents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    }

    @Test("a verified download reports progress, then installed, and lands under its file name")
    func successfulDownload() async throws {
        let body = randomBody(256 * 1024)
        let model = makeModel(body: body)
        ModelURLProtocol.serve(model.fileName, .init(body: body))
        let store = makeStore([model])
        #expect(store.installedFileURL(for: model) == nil)

        let seen = OSAllocatedUnfairLock(initialState: [SpeechModelInstallState]())
        let observer = Task {
            for await snapshot in store.installStates {
                if let state = snapshot[model.id] { seen.withLock { $0.append(state) } }
            }
        }
        try await store.download(model)
        try await Task.sleep(for: .milliseconds(100))
        observer.cancel()

        let url = try #require(store.installedFileURL(for: model))
        #expect(try Data(contentsOf: url) == body)
        #expect(directoryContents() == [model.fileName])   // no staging file left behind
        let states = seen.withLock { $0 }
        #expect(states.first == .notInstalled)
        #expect(states.contains { if case .downloading = $0 { true } else { false } })
        #expect(states.last == .installed)
    }

    @Test("a checksum mismatch fails and removes the file")
    func checksumMismatch() async throws {
        let body = randomBody(64 * 1024)
        let model = makeModel(body: body, sha256: String(repeating: "0", count: 64))
        ModelURLProtocol.serve(model.fileName, .init(body: body))
        let store = makeStore([model])

        await #expect(throws: SpeechModelStore.StoreError.verificationFailed) { try await store.download(model) }
        #expect(store.installedFileURL(for: model) == nil)
        #expect(directoryContents().isEmpty)
        let snapshot = await first(store.installStates) { _ in true }
        guard case .failed = snapshot?[model.id] else {
            Issue.record("expected .failed, got \(String(describing: snapshot?[model.id]))")
            return
        }
    }

    @Test("an HTTP error fails without leaving a file")
    func httpError() async throws {
        let model = makeModel(body: Data("missing".utf8))
        ModelURLProtocol.serve(model.fileName, .init(status: 404, body: Data("missing".utf8)))
        let store = makeStore([model])

        await #expect(throws: SpeechModelStore.StoreError.httpStatus(404)) { try await store.download(model) }
        #expect(directoryContents().isEmpty)
    }

    @Test("delete removes an installed model")
    func delete() async throws {
        let body = randomBody(32 * 1024)
        let model = makeModel(body: body)
        ModelURLProtocol.serve(model.fileName, .init(body: body))
        let store = makeStore([model])
        try await store.download(model)
        #expect(store.installedFileURL(for: model) != nil)

        try store.delete(model)
        #expect(store.installedFileURL(for: model) == nil)
        #expect(directoryContents().isEmpty)
        let snapshot = await first(store.installStates) { _ in true }
        #expect(snapshot?[model.id] == .notInstalled)
    }

    @Test("cancelling the download task cancels the download")
    func cancellation() async throws {
        let body = randomBody(128 * 1024)
        let model = makeModel(body: body)
        ModelURLProtocol.serve(model.fileName, .init(body: body, stall: true))
        let store = makeStore([model])

        let download = Task { try await store.download(model) }
        let downloading = await first(store.installStates) {
            if case .downloading = $0[model.id] { true } else { false }
        }
        #expect(downloading != nil)
        download.cancel()
        await #expect(throws: CancellationError.self) { try await download.value }
        let snapshot = await first(store.installStates) { _ in true }
        #expect(snapshot?[model.id] == .notInstalled)
        #expect(store.installedFileURL(for: model) == nil)
    }

    @Test("deleting during verification wins: the file doesn't come back")
    func deleteDuringVerification() async throws {
        let body = randomBody(64 * 1024)
        let model = makeModel(body: body)
        ModelURLProtocol.serve(model.fileName, .init(body: body))
        let store = makeStore([model])
        store.setBeforeInstallHook { try? store.delete(model) }

        await #expect(throws: CancellationError.self) { try await store.download(model) }
        #expect(store.installedFileURL(for: model) == nil)
        #expect(directoryContents().isEmpty)
        let snapshot = await first(store.installStates) { _ in true }
        #expect(snapshot?[model.id] == .notInstalled)
    }

    @Test("a download requested from an already-cancelled task ends at once", .timeLimit(.minutes(1)))
    func cancelledBeforeStart() async throws {
        let body = randomBody(16 * 1024)
        let model = makeModel(body: body)
        ModelURLProtocol.serve(model.fileName, .init(body: body, stall: true))
        let store = makeStore([model])
        let download = Task {
            while !Task.isCancelled { await Task.yield() }
            try await store.download(model)
        }
        download.cancel()
        await #expect(throws: CancellationError.self) { try await download.value }
        // A later download of the same model is not blocked by a leftover task entry.
        ModelURLProtocol.serve(model.fileName, .init(body: body))
        try await store.download(model)
        #expect(store.installedFileURL(for: model) != nil)
    }

    @Test("leftover staging files are removed when the store starts")
    func sweepsStagingFiles() throws {
        let model = makeModel(body: randomBody(16))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: 8).write(to: directory.appending(path: ".\(model.fileName).\(UUID().uuidString).partial"))
        try Data(count: 8).write(to: directory.appending(path: "keep-me.txt"))
        _ = makeStore([model])
        #expect(directoryContents() == ["keep-me.txt"])
    }

    @Test("deleting a model that isn't in the catalog throws")
    func deleteUnknown() throws {
        let store = makeStore([makeModel(body: randomBody(16))])
        let stranger = makeModel(body: randomBody(16))
        #expect(throws: SpeechModelStore.StoreError.notInCatalog) { try store.delete(stranger) }
    }

    @Test("download URLs are pinned to one Hugging Face commit; the default session keeps nothing")
    func pinnedAndEphemeral() {
        for model in SpeechModel.catalog {
            #expect(model.downloadURL.absoluteString ==
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/\(model.fileName)")
        }
        let configuration = SpeechModelStore.downloadConfiguration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
    }

    @Test("a file of the wrong size doesn't count as installed")
    func wrongSizeNotInstalled() throws {
        let model = makeModel(body: randomBody(1_000))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: 10).write(to: directory.appending(path: model.fileName))
        #expect(makeStore([model]).installedFileURL(for: model) == nil)
    }
}

// MARK: - Transcriber

/// A model store with a fixed answer for `installedFileURL`; never downloads.
private struct FixedModelStore: SpeechModelManaging {
    var fileURL: URL?
    var installStates: AsyncStream<[SpeechModel.ID: SpeechModelInstallState]> { AsyncStream { $0.finish() } }
    func installedFileURL(for model: SpeechModel) -> URL? { fileURL }
    func download(_ model: SpeechModel) async throws {}
    func delete(_ model: SpeechModel) throws {}
}

/// A model store whose file can disappear, like a model deleted from Settings.
private final class SwitchableModelStore: SpeechModelManaging, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private let forward: (any SpeechModelManaging)?

    init(fileURL: URL?, forwardingTo forward: (any SpeechModelManaging)? = nil) {
        self.forward = forward
        lock.withLock { $0 = fileURL }
    }

    var fileURL: URL? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }

    var installStates: AsyncStream<[SpeechModel.ID: SpeechModelInstallState]> { AsyncStream { $0.finish() } }
    func installedFileURL(for model: SpeechModel) -> URL? { fileURL }
    func download(_ model: SpeechModel) async throws { try await forward?.download(model) }
    func delete(_ model: SpeechModel) throws {}
}

@Suite("WhisperTranscriber")
struct WhisperTranscriberTests {

    @Test("starting without a downloaded model reports needsModel")
    func needsModel() async throws {
        let transcriber = WhisperTranscriber(modelStore: FixedModelStore(fileURL: nil))
        transcriber.start(model: try #require(SpeechModel.named("tiny")), language: "auto")
        let state = await first(transcriber.states) { $0 != .off }
        #expect(state == .needsModel)
    }

    /// Writes `bytes` to a temporary file and returns a catalog-style model for it whose
    /// size matches and whose SHA-256 is `sha256` (default: the bytes' real hash).
    private func modelFile(_ bytes: Data, sha256: String? = nil) throws -> (SpeechModel, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "notchpilot-model-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        let digest = sha256 ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let model = SpeechModel(id: "test", displayName: "Test", summary: "", fileName: url.lastPathComponent,
                                sizeBytes: Int64(bytes.count), sha256: digest)
        return (model, url)
    }

    private func unavailableReason(_ transcriber: WhisperTranscriber) async -> String? {
        let state = await first(transcriber.states) { $0 != .off && $0 != .loadingModel }
        guard case .unavailable(let reason) = state else {
            Issue.record("expected .unavailable, got \(String(describing: state))")
            return nil
        }
        return reason
    }

    @Test("a verified file whisper can't parse reports unavailable instead of crashing")
    func unparseableModel() async throws {
        let (model, url) = try modelFile(Data(repeating: 0x42, count: 4_096))
        defer { try? FileManager.default.removeItem(at: url) }
        let transcriber = WhisperTranscriber(modelStore: FixedModelStore(fileURL: url))
        transcriber.start(model: model, language: "auto")
        #expect(await unavailableReason(transcriber)?.contains("couldn’t be loaded") == true)
    }

    @Test("a file of the right size but wrong bytes is rejected before whisper parses it")
    func tamperedModel() async throws {
        let (model, url) = try modelFile(Data(repeating: 0x42, count: 4_096), sha256: String(repeating: "a", count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        let transcriber = WhisperTranscriber(modelStore: FixedModelStore(fileURL: url))
        transcriber.start(model: model, language: "auto")
        #expect(await unavailableReason(transcriber)?.contains("damaged") == true)
    }

    @Test("WhisperContext checks the hash of the bytes it loads")
    func contextHashCheck() throws {
        let (model, url) = try modelFile(Data(repeating: 0x42, count: 1_024), sha256: String(repeating: "b", count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: WhisperContext.LoadError.damaged) { try WhisperContext(model: model, fileURL: url) }
        let missing = url.deletingLastPathComponent().appending(path: "missing-\(UUID().uuidString).bin")
        #expect(throws: WhisperContext.LoadError.unreadable) { try WhisperContext(model: model, fileURL: missing) }
    }

    @Test("start re-checks the file each time: a model that disappeared reports needsModel")
    func recheckOnStart() async throws {
        let (model, url) = try modelFile(Data(repeating: 0x42, count: 4_096))
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SwitchableModelStore(fileURL: url)
        let transcriber = WhisperTranscriber(modelStore: store)
        transcriber.start(model: model, language: "auto")
        _ = await unavailableReason(transcriber)
        store.fileURL = nil
        transcriber.start(model: model, language: "auto")
        #expect(await first(transcriber.states) { $0 == .needsModel } == .needsModel)
        #expect(!transcriber.isModelLoaded)
    }

    @Test("shutdown returns promptly and leaves the transcriber off")
    func shutdownWhenIdle() async throws {
        let transcriber = WhisperTranscriber(modelStore: FixedModelStore(fileURL: nil))
        transcriber.start(model: try #require(SpeechModel.named("tiny")), language: "auto")
        transcriber.shutdown()
        let state = await first(transcriber.states) { _ in true }
        #expect(state == .off)
    }

    @Test("audio is ignored while not listening")
    func ignoresAudioWhenOff() async throws {
        let transcriber = WhisperTranscriber(modelStore: FixedModelStore(fileURL: nil))
        let block = [Float](repeating: 0.3, count: 960)
        block.withUnsafeBufferPointer { transcriber.process($0, frames: 480, format: PCMFormat(sampleRate: 48_000, channelCount: 2)) }
        transcriber.stop()
        let transcript = await first(transcriber.transcripts) { _ in true }
        #expect(transcript == Transcript())
    }
}

// MARK: - Real model (opt-in)

/// Serialized: the memory test measures the whole process, so no other model may be
/// loaded alongside it, and all tests share one download folder.
@Suite("Whisper integration", .serialized)
struct WhisperIntegrationTests {
    static let enabled = ProcessInfo.processInfo.environment["NOTCHPILOT_WHISPER_INTEGRATION"] == "1"

    @Test("ggml-tiny transcribes speech generated by `say`",
          .enabled(if: enabled, "Set NOTCHPILOT_WHISPER_INTEGRATION=1 to download ggml-tiny.bin (78 MB) from huggingface.co and run whisper"),
          .timeLimit(.minutes(10)))
    func transcribesSay() async throws {
        let model = try #require(SpeechModel.named("tiny"))
        // Fixed directory so reruns reuse the verified download.
        let directory = FileManager.default.temporaryDirectory.appending(path: "NotchPilotWhisperIntegration", directoryHint: .isDirectory)
        let store = SpeechModelStore(directory: directory)
        try await store.download(model)
        #expect(store.installedFileURL(for: model) != nil)

        // `say` writes 22.05 kHz mono AIFF; it is read back into memory and the temp file deleted.
        let aiff = FileManager.default.temporaryDirectory.appending(path: "notchpilot-say-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path(percentEncoded: false), "hello world, this is a test"]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: aiff)
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        // Interleave (non-interleaved float channels) the way the capture pipeline delivers it.
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for channel in 0..<channels {
            let data = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<frames { interleaved[frame * channels + channel] = data[frame] }
        }
        // Trailing silence so the utterance commits on its own.
        interleaved += [Float](repeating: 0, count: Int(format.sampleRate) * channels)

        let transcriber = WhisperTranscriber(modelStore: store)
        transcriber.start(model: model, language: "en")
        #expect(await first(transcriber.states, timeout: .seconds(60)) { $0 == .listening } == .listening)
        let pcmFormat = PCMFormat(sampleRate: format.sampleRate, channelCount: channels)
        let blockFrames = Int(format.sampleRate / 100)   // 10 ms blocks, like the consumer
        for start in stride(from: 0, to: interleaved.count / channels, by: blockFrames) {
            let count = min(blockFrames, interleaved.count / channels - start)
            interleaved[(start * channels)..<((start + count) * channels)].withUnsafeBufferPointer {
                transcriber.process($0, frames: count, format: pcmFormat)
            }
            try await Task.sleep(for: .milliseconds(2))   // pending-block bound is 64
        }
        let transcript = await first(transcriber.transcripts, timeout: .seconds(120)) { !$0.finalText.isEmpty }
        transcriber.shutdown()   // free the model before the test process exits
        let text = transcript?.finalText ?? ""
        print("whisper integration transcript: \(text)")
        let words = text.lowercased()
        #expect(words.contains("hello"))
        #expect(words.contains("test"))
    }

    @Test("deleting the model in use frees it; an unsupported rate fails instead of dropping audio",
          .enabled(if: enabled, "Set NOTCHPILOT_WHISPER_INTEGRATION=1 to download ggml-tiny.bin (78 MB) from huggingface.co and run whisper"),
          .timeLimit(.minutes(10)))
    func deleteInUseAndBadRate() async throws {
        let model = try #require(SpeechModel.named("tiny"))
        let directory = FileManager.default.temporaryDirectory.appending(path: "NotchPilotWhisperIntegration", directoryHint: .isDirectory)
        let real = SpeechModelStore(directory: directory)
        try await real.download(model)
        let store = SwitchableModelStore(fileURL: real.installedFileURL(for: model))
        let transcriber = WhisperTranscriber(modelStore: store)
        defer { transcriber.shutdown() }

        transcriber.start(model: model, language: "auto")
        #expect(await first(transcriber.states, timeout: .seconds(60)) { $0 == .listening } == .listening)
        #expect(transcriber.isModelLoaded)

        // A sample rate the resampler can't handle ends listening with a visible failure.
        let block = [Float](repeating: 0.1, count: 64)
        block.withUnsafeBufferPointer { transcriber.process($0, frames: 64, format: PCMFormat(sampleRate: 0, channelCount: 1)) }
        let failed = await first(transcriber.states) { if case .failed = $0 { true } else { false } }
        #expect(failed == .failed("Unsupported audio format (0 Hz)."))

        // Listening again reuses the loaded model; then the file disappears (deleted in Settings).
        transcriber.start(model: model, language: "auto")
        #expect(await first(transcriber.states) { $0 == .listening } == .listening)
        store.fileURL = nil
        transcriber.start(model: model, language: "auto")   // same model and language
        #expect(await first(transcriber.states) { $0 == .needsModel } == .needsModel)
        #expect(!transcriber.isModelLoaded)
    }

    /// Process memory as Activity Monitor's "Memory" column counts it (phys_footprint),
    /// plus the peak so far, in MB.
    static func footprintMB() -> (current: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    @Test("memory: a loaded model fits an 8 GB Mac, and stopping frees it after the idle delay",
          .enabled(if: enabled, "Set NOTCHPILOT_WHISPER_INTEGRATION=1 (and optionally NOTCHPILOT_WHISPER_MODEL=base|small) to measure memory with a real model"),
          .timeLimit(.minutes(10)))
    func memoryBudgetAndIdleUnload() async throws {
        let id = ProcessInfo.processInfo.environment["NOTCHPILOT_WHISPER_MODEL"] ?? "tiny"
        let model = try #require(SpeechModel.named(id))
        let directory = FileManager.default.temporaryDirectory.appending(path: "NotchPilotWhisperIntegration", directoryHint: .isDirectory)
        let store = SpeechModelStore(directory: directory)
        try await store.download(model)
        let before = Self.footprintMB().current

        let transcriber = WhisperTranscriber(modelStore: store, windowConfiguration: .default, idleUnloadDelay: .seconds(1))
        defer { transcriber.shutdown() }
        transcriber.start(model: model, language: "en")
        #expect(await first(transcriber.states, timeout: .seconds(60)) { $0 == .listening } == .listening)

        // One full 15 s window of speech-level noise, so whisper allocates its working buffers.
        var noise = [Float](repeating: 0, count: 16_000)
        for i in noise.indices { noise[i] = Float.random(in: -0.2...0.2) }
        for _ in 0..<15 {
            noise.withUnsafeBufferPointer { transcriber.process($0, frames: 16_000, format: PCMFormat(sampleRate: 16_000, channelCount: 1)) }
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .seconds(3))
        let loaded = Self.footprintMB()
        print(String(format: "whisper memory [%@]: before %.0f MB, loaded %.0f MB (model + buffers %.0f MB), peak %.0f MB",
                     model.id, before, loaded.current, loaded.current - before, loaded.peak))
        // Budget for the default model on an 8 GB Mac shared with other apps.
        if model.id == SpeechModel.recommendedID { #expect(loaded.current - before < 450) }   // measured ~330 MB in a fresh process

        transcriber.stop()
        #expect(transcriber.isModelLoaded)   // still loaded right after stop
        try await Task.sleep(for: .seconds(3))
        #expect(!transcriber.isModelLoaded)  // freed after the idle delay
        let after = Self.footprintMB().current
        print(String(format: "whisper memory [%@]: after idle unload %.0f MB", model.id, after))
    }

    @Test("an earlier stop's idle unload doesn't fire after start and a second stop",
          .enabled(if: enabled, "Set NOTCHPILOT_WHISPER_INTEGRATION=1 to download ggml-tiny.bin (78 MB) from huggingface.co and run whisper"),
          .timeLimit(.minutes(10)))
    func restartCancelsIdleUnload() async throws {
        let model = try #require(SpeechModel.named("tiny"))
        let directory = FileManager.default.temporaryDirectory.appending(path: "NotchPilotWhisperIntegration", directoryHint: .isDirectory)
        let store = SpeechModelStore(directory: directory)
        try await store.download(model)
        let transcriber = WhisperTranscriber(modelStore: store, windowConfiguration: .default, idleUnloadDelay: .seconds(2))
        defer { transcriber.shutdown() }
        transcriber.start(model: model, language: "en")
        #expect(await first(transcriber.states, timeout: .seconds(60)) { $0 == .listening } == .listening)
        // stop (schedules unload at t+2 s), start, stop again at ~t+1 s (schedules t+3 s).
        transcriber.stop()
        try await Task.sleep(for: .milliseconds(500))
        transcriber.start(model: model, language: "en")
        #expect(await first(transcriber.states) { $0 == .listening } == .listening)
        try await Task.sleep(for: .milliseconds(500))
        transcriber.stop()
        // Past the first stop's deadline: only the token keeps that unload from firing.
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(transcriber.isModelLoaded)
        // Past the second stop's deadline: now it is freed.
        try await Task.sleep(for: .seconds(2))
        #expect(!transcriber.isModelLoaded)
    }
}
