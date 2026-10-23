import Foundation

/// Structured capture failures with user-facing wording. Messages describe what happened
/// and how to fix it, without apologising (HIG › Writing).
public enum CaptureError: Error, Sendable, Equatable {
    /// Screen & System Audio Recording permission is missing or was denied.
    case permissionDenied
    /// No display/content was available to attach an audio stream to.
    case audioSourceUnavailable(String)
    /// The stream delivered audio NotchPilot cannot convert to its PCM format.
    case unsupportedFormat(String)
    /// ScreenCaptureKit stopped or failed to start the stream.
    case streamFailed(String)
    /// Stopping the stream did not complete cleanly. Capture is no longer running.
    case shutdownFailed(String)
    /// The ring buffer or converter could not be allocated.
    case resourceAllocationFailed

    public var title: String {
        switch self {
        case .permissionDenied: "Permission Needed"
        case .audioSourceUnavailable: "No Audio Source"
        case .unsupportedFormat: "Unsupported Audio Format"
        case .streamFailed: "Capture Stopped"
        case .shutdownFailed: "Capture Didn’t Stop Cleanly"
        case .resourceAllocationFailed: "Not Enough Memory"
        }
    }

    public var message: String {
        switch self {
        case .permissionDenied:
            "Allow NotchPilot in Screen & System Audio Recording (Screen Recording on macOS 14), then start capture again."
        case .audioSourceUnavailable:
            "No display to capture system audio from. Wake or connect a display, then try again."
        case .unsupportedFormat:
            "System audio arrived in a format NotchPilot can’t convert, so capture stopped."
        case .streamFailed:
            "System audio capture stopped. Start capture to try again."
        case .shutdownFailed:
            "Capture is off, but the stream didn’t close cleanly."
        case .resourceAllocationFailed:
            "NotchPilot couldn’t reserve memory for the audio buffer. Quit other apps, then try again."
        }
    }

    /// Raw system detail, kept out of `message` and shown only as a tooltip.
    public var technicalDetail: String? {
        switch self {
        case .audioSourceUnavailable(let detail), .unsupportedFormat(let detail),
             .streamFailed(let detail), .shutdownFailed(let detail): detail
        case .permissionDenied, .resourceAllocationFailed: nil
        }
    }

    /// Whether the UI should offer a shortcut to the privacy settings pane.
    public var offersPrivacySettings: Bool { self == .permissionDenied }
}
