import Foundation

/// Decides when to run whisper over the rolling 16 kHz audio window, and when the
/// utterance in it is complete. Engine-agnostic and free of I/O, so it is unit-tested
/// without a model.
///
/// whisper.cpp is a batch recogniser. Streaming is approximated by re-transcribing the
/// whole current window every `step` (the result becomes the partial text) and, once the
/// utterance ends, transcribing it one last time and committing that as final text:
///
/// * An utterance ends after `silenceToCommit` of quiet following speech, or when the
///   window reaches `maxWindow`.
/// * A window with no speech at all is never transcribed (whisper invents text on
///   silence); it is trimmed to a short pre-roll so the start of the next word survives.
/// * At most one inference runs at a time. If one takes longer than `step`, the next one
///   simply starts with the newest audio when it finishes, instead of a backlog forming.
/// * Memory is bounded even when whisper can't keep up (Intel, large models): while a pass
///   runs, at most 2 × `maxWindow` is held (the audio being transcribed plus the newest
///   `maxWindow`); older audio is dropped. Each pass covers at most `maxWindow`.
///
/// Speech detection is a plain RMS threshold per 100 ms frame; system audio is clean
/// enough that this is a good proxy, and whisper itself rejects the rest.
struct WhisperWindowing {
    struct Configuration: Equatable {
        var sampleRate = 16_000
        /// Re-transcription interval while speech continues.
        var step: Double
        var maxWindow: Double = 15
        var silenceToCommit: Double = 0.7
        /// Frames at or above this RMS (about −46 dBFS) count as speech.
        var speechRMS: Float = 0.005
        var frame: Double = 0.1
        /// Audio kept ahead of the first speech frame.
        var preRoll: Double = 0.3

        /// 1 s on Apple silicon (Metal keeps up), 2 s on Intel (CPU only).
        static var `default`: Configuration {
            #if arch(arm64)
            Configuration(step: 1.0)
            #else
            Configuration(step: 2.0)
            #endif
        }

        var frameSamples: Int { max(1, Int(Double(sampleRate) * frame)) }
        var stepSamples: Int { Int(Double(sampleRate) * step) }
        var maxSamples: Int { Int(Double(sampleRate) * maxWindow) }
        var silenceFrames: Int { max(1, Int((silenceToCommit / frame).rounded())) }
        var preRollSamples: Int { Int(Double(sampleRate) * preRoll) }
    }

    enum Action: Equatable {
        /// Transcribe `samples` (a copy of the window) and show the text as partial.
        case partial([Float])
        /// Transcribe `samples`, commit the text, then call `didCommit(consumed:)`.
        case final([Float])
    }

    let configuration: Configuration
    private(set) var samples: [Float] = []
    /// Speech flag of each classified 100 ms frame, oldest first; `samples` beyond
    /// `frameFlags.count * frameSamples` are not classified yet.
    private var frameFlags: [Bool] = []
    private var speechFrames = 0
    private var trailingSilentFrames = 0
    private var samplesSinceInference = 0
    /// Samples dropped by the hard cap since the last action; a `.final` snapshot's start
    /// may already be gone when `didCommit` runs.
    private var droppedSinceAction = 0

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Seconds of speech-level audio in the window; feeds the hallucination filter.
    var speechSeconds: Double { Double(speechFrames) * configuration.frame }
    var hasSpeech: Bool { speechFrames > 0 }
    /// Most audio ever held: the pass in flight plus the newest `maxWindow`.
    var hardLimitSamples: Int { 2 * configuration.maxSamples }

    mutating func append(_ block: [Float]) {
        guard !block.isEmpty else { return }
        samples.append(contentsOf: block)
        samplesSinceInference += block.count
        analyzeNewFrames()
        let excess = samples.count - hardLimitSamples
        if excess > 0 {
            let dropped = dropFirst(wholeFramesCovering: excess)
            droppedSinceAction += dropped
        }
    }

    /// The next inference to run, or nil. Call after `append` whenever no inference is in
    /// flight. Trims a speech-free window to its pre-roll, and a window that grew past
    /// `maxWindow` while a pass ran to its newest `maxWindow`.
    mutating func nextAction() -> Action? {
        droppedSinceAction = 0
        let overLength = samples.count - configuration.maxSamples
        if overLength > 0 { dropFirst(wholeFramesCovering: overLength) }
        guard speechFrames > 0 else {
            let excess = samples.count - configuration.preRollSamples
            if excess > 0 { dropFirst(exactly: excess) }
            samplesSinceInference = 0
            return nil
        }
        let silentLongEnough = trailingSilentFrames >= configuration.silenceFrames
        if silentLongEnough || samples.count >= configuration.maxSamples {
            samplesSinceInference = 0
            return .final(samples)
        }
        if samplesSinceInference >= configuration.stepSamples {
            samplesSinceInference = 0
            return .partial(samples)
        }
        return nil
    }

    /// Removes the audio that a `.final` action transcribed; audio that arrived while it
    /// ran stays and starts the next utterance.
    mutating func didCommit(consumed: Int) {
        let remaining = max(0, consumed - droppedSinceAction)
        droppedSinceAction = 0
        dropFirst(exactly: min(remaining, samples.count))
    }

    mutating func reset() {
        self = WhisperWindowing(configuration: configuration)
    }

    // MARK: - Private

    /// Drops at least `count` samples, rounded up to whole classified frames so the frame
    /// statistics update without re-reading the window. Returns how many were dropped.
    @discardableResult
    private mutating func dropFirst(wholeFramesCovering count: Int) -> Int {
        let size = configuration.frameSamples
        let frames = min(frameFlags.count, (count + size - 1) / size)
        guard frames > 0 else { return 0 }
        let removedSpeech = frameFlags.prefix(frames).filter { $0 }.count
        frameFlags.removeFirst(frames)
        speechFrames -= removedSpeech
        if trailingSilentFrames > frameFlags.count { trailingSilentFrames = frameFlags.count }
        samples.removeFirst(frames * size)
        return frames * size
    }

    /// Drops exactly `count` samples and re-classifies what is left (at most a few seconds).
    private mutating func dropFirst(exactly count: Int) {
        guard count > 0 else { return }
        samples.removeFirst(count)
        frameFlags = []
        speechFrames = 0
        trailingSilentFrames = 0
        analyzeNewFrames()
    }

    private mutating func analyzeNewFrames() {
        let size = configuration.frameSamples
        var start = frameFlags.count * size
        while start + size <= samples.count {
            let isSpeech = Self.rms(samples[start..<(start + size)]) >= configuration.speechRMS
            frameFlags.append(isSpeech)
            if isSpeech {
                speechFrames += 1
                trailingSilentFrames = 0
            } else {
                trailingSilentFrames += 1
            }
            start += size
        }
    }

    static func rms(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in slice { sum += sample * sample }
        return (sum / Float(slice.count)).squareRoot()
    }
}

/// The language passed to whisper during one utterance. With "auto", whisper detects the
/// language once, on the first pass over at least `minimumSpeech` of speech, and that code
/// is then passed explicitly until the utterance is committed. This saves the detection
/// cost (an extra encoder pass) on every later pass and stops the language flickering
/// between partials.
struct UtteranceLanguage: Equatable {
    /// Below this much speech, detection is too unreliable to keep for the utterance.
    static let minimumSpeech = 1.0

    let requested: String
    private(set) var detected: String?

    init(requested: String) {
        self.requested = requested
    }

    /// What to pass to whisper for the next pass.
    var effective: String { requested == "auto" ? (detected ?? "auto") : requested }

    /// Records the language whisper reported for a pass that ran with `effective`.
    mutating func record(_ language: String?, speechSeconds: Double) {
        guard requested == "auto", detected == nil, let language, !language.isEmpty,
              speechSeconds >= Self.minimumSpeech else { return }
        detected = language
    }

    /// The utterance was committed; the next one detects again.
    mutating func utteranceDidEnd() {
        detected = nil
    }
}

/// Cleans whisper output before it reaches the transcript.
enum WhisperTextFilter {
    /// Phrases whisper is known to produce on silence or music (artefacts of its training
    /// subtitles). Dropped only when the window held little actual speech.
    static let silenceHallucinations: Set<String> = [
        "thank you", "thanks", "thank you very much", "thanks for watching",
        "thank you for watching", "thank you so much for watching", "you", "bye", "bye bye",
        "please subscribe", "subtitles by the amaraorg community",
    ]
    /// Below this much speech, a window's text must not be one of the phrases above.
    static let nearSilenceSeconds = 1.0

    /// Removes bracketed or parenthesised annotations ("[BLANK_AUDIO]", "(music)",
    /// "[Music]", "*laughs*") and known silence hallucinations; returns "" when nothing
    /// real is left.
    static func cleaned(_ raw: String, speechSeconds: Double) -> String {
        var text = raw
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\*[^*]*\*"#, #"♪+"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let letters = text.unicodeScalars.filter { CharacterSet.letters.union(.decimalDigits).contains($0) }
        guard !letters.isEmpty else { return "" }
        if speechSeconds < nearSilenceSeconds {
            let normalized = text.lowercased()
                .unicodeScalars.filter { CharacterSet.letters.union(.whitespaces).contains($0) }
            let key = String(String.UnicodeScalarView(normalized))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if silenceHallucinations.contains(key) { return "" }
        }
        return text
    }
}
