import CoreGraphics
import Testing
@testable import NotchPilotCore

private let layout = NotchPilotConfig.Layout()

/// 14" MacBook Pro-like display: 1512x982 points, 185x32 camera housing, 32 pt menu bar.
private let notched = DisplayMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                                     notchHeight: 32, notchWidth: 185)

/// External display without a camera housing, placed to the right of the main one.
private let external = DisplayMetrics(frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                                      visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055),
                                      notchHeight: 0, notchWidth: 0)

@Suite("IslandGeometry")
struct IslandGeometryTests {

    // MARK: Attachment

    @Test("a notched display with attachToNotch is attached")
    func notchedDisplayAttaches() {
        let geometry = IslandGeometry(config: layout, display: notched, attachToNotch: true)
        #expect(geometry.attachedToNotch)
        #expect(geometry.topInset == 32)
        #expect(geometry.headerHeight == 32)
    }

    @Test("attachToNotch=false floats the island even on a notched display")
    func attachDisabledFloats() {
        let geometry = IslandGeometry(config: layout, display: notched, attachToNotch: false)
        #expect(!geometry.attachedToNotch)
        #expect(geometry.topInset == 0)
        #expect(geometry.headerHeight == layout.compactSizeWithoutNotch.height)
    }

    @Test("a display without a notch never attaches")
    func noNotchFloats() {
        let geometry = IslandGeometry(config: layout, display: external, attachToNotch: true)
        #expect(!external.hasNotch)
        #expect(!geometry.attachedToNotch)
    }

    @Test("a notch shorter than the minimum uses the minimum height")
    func shortNotchUsesMinimumHeight() {
        var display = notched
        display.notchHeight = 20
        let geometry = IslandGeometry(config: layout, display: display, attachToNotch: true)
        #expect(geometry.topInset == layout.minimumNotchHeight)
    }

    // MARK: Island size

    @Test("attached compact island spans the notch plus two wings")
    func attachedCompactSize() {
        let geometry = IslandGeometry(config: layout, display: notched, attachToNotch: true)
        #expect(geometry.islandSize(for: .compact) == CGSize(width: 185 + 2 * layout.compactWingWidth, height: 32))
    }

    @Test("floating compact island uses the configured capsule size")
    func floatingCompactSize() {
        let geometry = IslandGeometry(config: layout, display: external, attachToNotch: true)
        #expect(geometry.islandSize(for: .compact) == layout.compactSizeWithoutNotch)
    }

    @Test("expanded height is the header plus the expanded content height",
          arguments: [(notched, true), (notched, false), (external, true)])
    func expandedHeight(display: DisplayMetrics, attach: Bool) {
        let geometry = IslandGeometry(config: layout, display: display, attachToNotch: attach)
        let size = geometry.islandSize(for: .expanded)
        #expect(size.height == geometry.headerHeight + layout.expandedContentSize.height)
        #expect(size.width == layout.expandedContentSize.width)
    }

    // MARK: Panel frame

    @Test("attached panel is centred and pinned to the physical top edge",
          arguments: [IslandPresentation.compact, .expanded])
    func attachedPanelFrame(presentation: IslandPresentation) {
        let geometry = IslandGeometry(config: layout, display: notched, attachToNotch: true)
        let frame = geometry.panelFrame(for: presentation)
        #expect(abs(frame.midX - notched.frame.midX) <= 1)
        #expect(frame.maxY == notched.frame.maxY)
        #expect(frame.height == geometry.islandSize(for: presentation).height + layout.shadowMargin)
    }

    @Test("floating panel is centred and pinned below the menu bar",
          arguments: [IslandPresentation.compact, .expanded])
    func floatingPanelFrame(presentation: IslandPresentation) {
        let geometry = IslandGeometry(config: layout, display: external, attachToNotch: true)
        let frame = geometry.panelFrame(for: presentation)
        #expect(abs(frame.midX - external.frame.midX) <= 1)
        #expect(frame.maxY == external.visibleFrame.maxY - layout.floatingTopMargin)
    }

    @Test("on a narrow display the island and panel are clamped inside the screen")
    func clampedToSmallDisplay() {
        let small = DisplayMetrics(frame: CGRect(x: 100, y: 0, width: 300, height: 200),
                                   visibleFrame: CGRect(x: 100, y: 0, width: 300, height: 180),
                                   notchHeight: 0, notchWidth: 0)
        let geometry = IslandGeometry(config: layout, display: small, attachToNotch: true)
        let island = geometry.islandSize(for: .expanded)
        #expect(island.width == 300 - 2 * layout.shadowMargin)

        let frame = geometry.panelFrame(for: .expanded)
        #expect(frame.minX >= small.frame.minX)
        #expect(frame.maxX <= small.frame.maxX)
        #expect(frame.minY >= small.frame.minY)
    }

    // MARK: Shape

    @Test("attached island has square top corners and concave shoulders")
    func attachedCornerRadii() {
        let geometry = IslandGeometry(config: layout, display: notched, attachToNotch: true)
        #expect(geometry.topCornerRadius(for: .compact) == 0)
        #expect(geometry.topCornerRadius(for: .expanded) == 0)
        #expect(geometry.bottomCornerRadius(for: .compact) == layout.compactCornerRadius)
        #expect(geometry.bottomCornerRadius(for: .expanded) == layout.expandedCornerRadius)
        #expect(geometry.shoulderRadius == layout.shoulderRadius)
    }

    @Test("floating island is rounded on all corners and has no shoulders")
    func floatingCornerRadii() {
        let geometry = IslandGeometry(config: layout, display: external, attachToNotch: true)
        #expect(geometry.topCornerRadius(for: .compact) == layout.compactCornerRadius)
        #expect(geometry.topCornerRadius(for: .expanded) == layout.expandedCornerRadius)
        #expect(geometry.bottomCornerRadius(for: .expanded) == layout.expandedCornerRadius)
        #expect(geometry.shoulderRadius == 0)
    }
}
