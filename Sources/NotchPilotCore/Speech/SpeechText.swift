import Foundation

/// Pure helpers behind `WhisperTranscriber`: downmixing captured blocks and keeping the
/// rolling transcript bounded. No framework state, so they are unit-tested directly.
enum SpeechText {
    /// Default cap for `Transcript.finalText`.
    static let finalTextLimit = 20_000

    /// Averages interleaved frames into one mono channel. Reads at most `frames` frames and
    /// never past the end of `samples`.
    static func downmixToMono(_ samples: UnsafeBufferPointer<Float>, frames: Int, channels: Int) -> [Float] {
        guard channels > 0, frames > 0 else { return [] }
        let frameCount = min(frames, samples.count / channels)
        guard channels > 1 else { return Array(samples.prefix(frameCount)) }
        let scale = 1 / Float(channels)
        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let base = frame * channels
            var sum: Float = 0
            for channel in 0..<channels { sum += samples[base + channel] }
            mono[frame] = sum * scale
        }
        return mono
    }

    /// Appends a finished utterance to the completed text and enforces the cap.
    static func appending(_ utterance: String, to finalText: String, limit: Int = finalTextLimit) -> String {
        let utterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return finalText }
        let merged = finalText.isEmpty ? utterance : finalText + " " + utterance
        return trimmed(merged, limit: limit)
    }

    /// Keeps at most `limit` characters, dropping the oldest text. When the cut lands inside
    /// a word, the rest of that word is dropped too so the text starts cleanly.
    static func trimmed(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        let cutsWord = !(text[text.index(before: tail.startIndex)].isWhitespace)
        if cutsWord, let space = tail.firstIndex(where: \.isWhitespace) {
            return String(tail[tail.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        }
        return String(tail).trimmingCharacters(in: .whitespaces)
    }
}
