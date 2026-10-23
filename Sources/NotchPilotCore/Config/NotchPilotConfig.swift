import CoreGraphics
import Foundation

/// The single place for NotchPilot's tunables: island dimensions, animation timings,
/// audio behaviour and feature flags. Values are compile-time defaults; change them here
/// and rebuild. Every value is documented in README.md › Configuration.
public struct NotchPilotConfig: Sendable, Equatable {

    public struct Layout: Sendable, Equatable {
        /// Width of each side "wing" that flanks the camera housing in compact state.
        public var compactWingWidth: CGFloat = 40
        /// Compact size on displays without a camera housing (floating capsule).
        public var compactSizeWithoutNotch = CGSize(width: 200, height: 32)
        /// Fallback compact height when a notched display reports no safe-area inset.
        public var minimumNotchHeight: CGFloat = 32
        /// Expanded content area, measured below the camera housing / top edge: capture
        /// status, level bar, live transcript, Ask row and footer.
        public var expandedContentSize = CGSize(width: 460, height: 208)
        /// Extra expanded height while an Ask is in progress or has failed (one-row notice).
        public var expandedNoticeHeight: CGFloat = 74
        /// Extra expanded height while a reply is shown (about five lines of text).
        public var expandedReplyHeight: CGFloat = 140
        /// Bottom corner radius in compact and expanded states.
        public var compactCornerRadius: CGFloat = 12
        public var expandedCornerRadius: CGFloat = 24
        /// Concave "shoulder" radius where a notch-attached island meets the menu bar.
        public var shoulderRadius: CGFloat = 8
        /// Gap between the menu bar and a floating (non-notch) island.
        public var floatingTopMargin: CGFloat = 6
        /// Transparent margin around the island so its shadow is not clipped.
        public var shadowMargin: CGFloat = 18
        /// Inset that keeps content concentric with the island's rounded edge.
        public var contentInset: CGFloat = 14
        public init() {}
    }

    public struct Animation: Sendable, Equatable {
        /// Spring used to open the island (seconds / damping fraction).
        public var expandResponse: Double = 0.42
        public var expandDamping: Double = 0.80
        /// Spring used to close it: slightly faster and less bouncy than opening.
        public var collapseResponse: Double = 0.34
        public var collapseDamping: Double = 0.92
        /// Cross-fade used instead of springs when Reduce Motion is on.
        public var reducedMotionFade: Double = 0.18
        /// How long the pointer must rest on the island before hover-expansion (if enabled).
        public var hoverExpandDelay: Double = 0.35
        /// UI refresh rate for the level meter, in Hz. Bounded so UI work stays cheap.
        public var meterRefreshHz: Double = 20
        public init() {}
    }

    public struct Audio: Sendable, Equatable {
        /// Stable PCM format published to the C++ ring: Float32, interleaved.
        public var sampleRate: Int = 48_000
        public var channelCount: Int = 2
        /// Ring capacity; rounded up to a power of two by the ring itself.
        public var ringCapacityFrames: Int = 1 << 15     // ~0.68 s at 48 kHz
        /// Largest buffer the capture callback accepts in one call. Larger buffers are
        /// rejected (counted) instead of triggering an allocation on the audio path.
        public var maxFramesPerCallback: Int = 8_192
        /// Block size the consumer drains and analyses.
        public var consumerBlockFrames: Int = 1_024
        /// Consumer polling interval in seconds (non-blocking timer).
        public var consumerInterval: Double = 0.010
        /// Exclude NotchPilot's own audio from capture.
        public var excludesCurrentProcessAudio = true
        public init() {}
    }

    public struct Features: Sendable, Equatable {
        /// Expand when the pointer rests on the island (off: click to expand).
        public var expandOnHover = false
        /// Attach to the camera housing on displays that have one.
        public var attachToNotch = true
        /// Keep the island visible over full-screen apps.
        public var showOverFullScreenApps = false
        /// Exclude the panel from window sharing / capture (`NSWindow.sharingType = .none`).
        public var excludeFromScreenSharing = true
        /// Show buffer telemetry (dropped and rejected frames) in the expanded island.
        /// Diagnostic; off by default.
        public var showTelemetry = false
        public init() {}
    }

    public var layout = Layout()
    public var animation = Animation()
    public var audio = Audio()
    public var features = Features()

    public init() {}

    public static let `default` = NotchPilotConfig()
}
