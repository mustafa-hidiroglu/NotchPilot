import Foundation

/// When the island offers Summarize. Never automatic: this only decides whether the button
/// is shown; a summary is sent only when the person presses it (or the status-menu item).
public enum SummaryEligibility {
    /// Below this, a summary would mostly restate the transcript.
    public static let minimumWords = 30

    public static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// The island's Summarize button: capture has stopped and there is enough text.
    public static func offersSummary(for transcript: Transcript, isCapturing: Bool) -> Bool {
        !isCapturing && wordCount(transcript.fullText) >= minimumWords
    }
}

extension AskPurpose {
    /// Only an answer may carry the optional screenshot; a summary is built from the
    /// transcript alone and never attaches one, even with Include Screen on.
    public var sendsScreenshot: Bool { self == .answer }
}
