import Foundation
import Speech
import Testing
@testable import NotchPilotCore

@Suite("SpeechText downmix")
struct SpeechDownmixTests {

    @Test("stereo frames average to one mono sample each")
    func stereoAverages() {
        let interleaved: [Float] = [1, 0, 0.5, 0.5, -1, 1, 0.2, 0.4]
        let mono = interleaved.withUnsafeBufferPointer { SpeechText.downmixToMono($0, frames: 4, channels: 2) }
        #expect(mono.count == 4)
        let expected: [Float] = [0.5, 0.5, 0, 0.3]
        for (value, want) in zip(mono, expected) { #expect(abs(value - want) < 1e-6) }
    }

    @Test("mono input passes through unchanged")
    func monoPassthrough() {
        let samples: [Float] = [0.1, -0.2, 0.3]
        let mono = samples.withUnsafeBufferPointer { SpeechText.downmixToMono($0, frames: 3, channels: 1) }
        #expect(mono == samples)
    }

    @Test("never reads past the buffer when frames overstates it")
    func clampsToBuffer() {
        let interleaved: [Float] = [1, 1, 2, 2, 3]
        let mono = interleaved.withUnsafeBufferPointer { SpeechText.downmixToMono($0, frames: 10, channels: 2) }
        #expect(mono == [1, 2])
    }

    @Test("zero channels or frames yields nothing")
    func empty() {
        let samples: [Float] = [1, 2]
        #expect(samples.withUnsafeBufferPointer { SpeechText.downmixToMono($0, frames: 2, channels: 0) }.isEmpty)
        #expect(samples.withUnsafeBufferPointer { SpeechText.downmixToMono($0, frames: 0, channels: 2) }.isEmpty)
    }
}

@Suite("SpeechText transcript bounds")
struct SpeechTrimTests {

    @Test("text within the cap is unchanged")
    func underCap() {
        #expect(SpeechText.trimmed("hello world", limit: 20) == "hello world")
    }

    @Test("drops the oldest text and the partial word at the cut")
    func cutsAtWordBoundary() {
        let trimmed = SpeechText.trimmed("hello there friend", limit: 10)
        #expect(trimmed == "friend")
        #expect(trimmed.count <= 10)
    }

    @Test("keeps the whole tail when the cut falls on a space")
    func cutOnSpace() {
        #expect(SpeechText.trimmed("hello there friend", limit: 12) == "there friend")
    }

    @Test("one long word is cut hard rather than emptied")
    func longWord() {
        #expect(SpeechText.trimmed("abcdefghij", limit: 4) == "ghij")
    }

    @Test("appending joins with one space and ignores blank utterances")
    func appending() {
        #expect(SpeechText.appending("  first.  ", to: "") == "first.")
        #expect(SpeechText.appending("second.", to: "first.") == "first. second.")
        #expect(SpeechText.appending("   ", to: "first.") == "first.")
    }

    @Test("appending enforces the cap")
    func appendingCaps() {
        var text = ""
        for index in 0..<5_000 { text = SpeechText.appending("word\(index)", to: text) }
        #expect(text.count <= SpeechText.finalTextLimit)
        #expect(text.hasSuffix("word4999"))
        #expect(text.hasPrefix("word"))
    }
}

@Suite("Transcript")
struct TranscriptTests {

    @Test("fullText joins final and partial text")
    func fullText() {
        #expect(Transcript().fullText == "")
        #expect(Transcript(finalText: "a b").fullText == "a b")
        #expect(Transcript(partialText: "c").fullText == "c")
        #expect(Transcript(finalText: "a b", partialText: "c").fullText == "a b c")
    }

    @Test("recentText returns the tail starting at a word")
    func recentText() {
        let transcript = Transcript(finalText: "one two three", partialText: "four")
        #expect(transcript.recentText(limit: 100) == "one two three four")
        #expect(transcript.recentText(limit: 9) == "four")
        #expect(transcript.recentText(limit: 11) == "three four")
    }
}

@Suite("SystemAudioTranscriber state")
struct SystemAudioTranscriberStateTests {

    private func transcriber(
        status: SFSpeechRecognizerAuthorizationStatus,
        unavailableReason: String = "Not on this Mac."
    ) -> SystemAudioTranscriber {
        SystemAudioTranscriber(locale: Locale(identifier: "en_US"),
                                         authorizationStatus: { status },
                                         makeRecognizer: { _ in .failure(.init(reason: unavailableReason)) })
    }

    private func firstStateAfterOff(_ transcriber: SystemAudioTranscriber) async -> TranscriptionState? {
        for await state in transcriber.states where state != .off { return state }
        return nil
    }

    @Test("starts off")
    func startsOff() async {
        let speech = transcriber(status: .authorized)
        var states = speech.states.makeAsyncIterator()
        #expect(await states.next() == .off)
    }

    @Test("reports unavailable when on-device recognition is unsupported")
    func unavailable() async {
        let speech = transcriber(status: .authorized, unavailableReason: "No on-device model.")
        speech.start()
        #expect(await firstStateAfterOff(speech) == .unavailable("No on-device model."))
    }

    @Test("reports needsPermission before the person has been asked")
    func needsPermission() async {
        let speech = transcriber(status: .notDetermined)
        speech.start()
        #expect(await firstStateAfterOff(speech) == .needsPermission)
    }

    @Test("reports permissionDenied when denied or restricted", arguments: [
        SFSpeechRecognizerAuthorizationStatus.denied, .restricted,
    ])
    func denied(status: SFSpeechRecognizerAuthorizationStatus) async {
        let speech = transcriber(status: status)
        speech.start()
        #expect(await firstStateAfterOff(speech) == .permissionDenied)
    }

    @Test("ignores audio while not listening")
    func ignoresAudioWhenOff() async {
        let speech = transcriber(status: .authorized)
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4]
        samples.withUnsafeBufferPointer {
            speech.process($0, frames: 2, format: PCMFormat(sampleRate: 48_000, channelCount: 2))
        }
        speech.clear()
        var transcripts = speech.transcripts.makeAsyncIterator()
        #expect(await transcripts.next() == Transcript())
    }
}
