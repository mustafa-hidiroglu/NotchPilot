import CoreGraphics

/// The two horizontal layouts of the island.
public enum IslandPresentation: Sendable, Equatable {
    case compact
    case expanded
}

/// Description of the display the island lives on, extracted from NSScreen so the layout
/// math stays pure and testable.
public struct DisplayMetrics: Sendable, Equatable {
    /// Full screen frame in global AppKit coordinates (origin bottom-left).
    public var frame: CGRect
    /// Frame excluding menu bar and Dock.
    public var visibleFrame: CGRect
    /// Height of the camera housing area (`safeAreaInsets.top`), 0 when there is none.
    public var notchHeight: CGFloat
    /// Width of the camera housing, 0 when there is none.
    public var notchWidth: CGFloat

    public init(frame: CGRect, visibleFrame: CGRect, notchHeight: CGFloat, notchWidth: CGFloat) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.notchHeight = notchHeight
        self.notchWidth = notchWidth
    }

    public var hasNotch: Bool { notchHeight > 0 && notchWidth > 0 }
}

/// Pure layout calculations shared by the panel controller and the SwiftUI view.
public struct IslandGeometry: Sendable, Equatable {
    public let config: NotchPilotConfig.Layout
    public let display: DisplayMetrics
    /// True when the island is drawn attached to the camera housing.
    public let attachedToNotch: Bool

    public init(config: NotchPilotConfig.Layout, display: DisplayMetrics, attachToNotch: Bool) {
        self.config = config
        self.display = display
        self.attachedToNotch = attachToNotch && display.hasNotch
    }

    /// Height of the band at the top of the island that the camera housing occupies.
    /// Content must stay below it.
    public var topInset: CGFloat {
        attachedToNotch ? max(display.notchHeight, config.minimumNotchHeight) : 0
    }

    /// Height of the top band shared by both presentations. Compact content lives here and
    /// stays in place when the island expands (it only moves outward with the edges).
    public var headerHeight: CGFloat {
        attachedToNotch ? topInset : config.compactSizeWithoutNotch.height
    }

    /// Size of the visible island shape for a presentation, clamped to the display.
    public func islandSize(for presentation: IslandPresentation) -> CGSize {
        let maxWidth = max(0, display.visibleFrame.width - 2 * (config.shadowMargin + shoulderRadius))
        let size: CGSize
        switch presentation {
        case .compact where attachedToNotch:
            size = CGSize(width: display.notchWidth + 2 * config.compactWingWidth, height: topInset)
        case .compact:
            size = config.compactSizeWithoutNotch
        case .expanded:
            let width = max(config.expandedContentSize.width,
                            attachedToNotch ? display.notchWidth + 2 * config.compactWingWidth : 0)
            size = CGSize(width: width, height: headerHeight + config.expandedContentSize.height)
        }
        return CGSize(width: min(size.width, maxWidth), height: size.height)
    }

    /// Panel frame (global coordinates) that hosts the island for a presentation:
    /// horizontally centred on the display, top edge pinned, padded for the shadow, and
    /// never outside the screen frame.
    public func panelFrame(for presentation: IslandPresentation) -> CGRect {
        let island = islandSize(for: presentation)
        // Shoulders flare outside the island body; the shadow margin covers them.
        let width = island.width + 2 * (config.shadowMargin + shoulderRadius)
        let height = island.height + config.shadowMargin
        // Attached: flush with the physical top edge (the island grows out of the housing).
        // Floating: just below the menu bar, inside the visible frame.
        let top = attachedToNotch ? display.frame.maxY : display.visibleFrame.maxY - config.floatingTopMargin
        var frame = CGRect(x: display.frame.midX - width / 2, y: top - height, width: width, height: height)
        frame.origin.x = min(max(frame.origin.x, display.frame.minX), display.frame.maxX - frame.width)
        frame.origin.y = max(frame.origin.y, display.frame.minY)
        return frame.integral
    }

    /// Corner radii for the island shape.
    public func bottomCornerRadius(for presentation: IslandPresentation) -> CGFloat {
        presentation == .compact ? config.compactCornerRadius : config.expandedCornerRadius
    }

    /// Floating islands are rounded on all four corners; attached ones have square top
    /// corners with concave shoulders that blend into the menu bar.
    public func topCornerRadius(for presentation: IslandPresentation) -> CGFloat {
        attachedToNotch ? 0 : bottomCornerRadius(for: presentation)
    }

    public var shoulderRadius: CGFloat { attachedToNotch ? config.shoulderRadius : 0 }
}
