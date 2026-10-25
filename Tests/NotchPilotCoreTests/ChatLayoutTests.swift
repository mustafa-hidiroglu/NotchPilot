import CoreGraphics
import Testing
@testable import NotchPilotCore

@Suite("Chat island size")
struct ChatLayoutTests {
    private let layout = NotchPilotConfig.Layout()

    @Test("the chat island fits a 13-inch MacBook Air at 1440 × 900 with the Dock showing")
    func fitsAir() {
        // M1 MacBook Air default scaling: 1440 × 900 points, 32 pt camera housing; a
        // default-size Dock at the bottom takes about 70 pt.
        let air = DisplayMetrics(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                 visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 798),
                                 notchHeight: 32, notchWidth: 186)
        let geometry = IslandGeometry(config: layout, display: air, attachToNotch: true)
        let size = geometry.islandSize(for: .expanded, accessoryHeight: layout.expandedChatHeight)
        #expect(size.height == geometry.headerHeight + layout.expandedContentSize.height + layout.expandedChatHeight)
        let frame = geometry.panelFrame(for: .expanded, accessoryHeight: layout.expandedChatHeight)
        #expect(frame.minY >= air.visibleFrame.minY)
        #expect(frame.maxY <= air.frame.maxY)
    }

    @Test("on a short screen the chat island is clamped to the visible height")
    func clampsShortScreen() {
        let short = DisplayMetrics(frame: CGRect(x: 0, y: 0, width: 1024, height: 640),
                                   visibleFrame: CGRect(x: 0, y: 200, width: 1024, height: 415),
                                   notchHeight: 0, notchWidth: 0)
        let geometry = IslandGeometry(config: layout, display: short, attachToNotch: true)
        let frame = geometry.panelFrame(for: .expanded, accessoryHeight: layout.expandedChatHeight)
        #expect(frame.minY >= short.visibleFrame.minY)
        #expect(frame.maxY <= short.visibleFrame.maxY)
    }

    @Test("the full Chat layout is kept on the Air; a very short screen hides the level and transcript rows")
    func compactRows() {
        let air = DisplayMetrics(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                 visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 798),
                                 notchHeight: 32, notchWidth: 186)
        #expect(!IslandGeometry(config: layout, display: air, attachToNotch: true).chatUsesCompactRows)

        // 1024 × 640 with a large Dock: the island loses 125 pt, the conversation keeps 123.
        let short = DisplayMetrics(frame: CGRect(x: 0, y: 0, width: 1024, height: 640),
                                   visibleFrame: CGRect(x: 0, y: 200, width: 1024, height: 415),
                                   notchHeight: 0, notchWidth: 0)
        #expect(!IslandGeometry(config: layout, display: short, attachToNotch: true).chatUsesCompactRows)

        let tiny = DisplayMetrics(frame: CGRect(x: 0, y: 0, width: 1024, height: 600),
                                  visibleFrame: CGRect(x: 0, y: 250, width: 1024, height: 325),
                                  notchHeight: 0, notchWidth: 0)
        let geometry = IslandGeometry(config: layout, display: tiny, attachToNotch: true)
        #expect(geometry.chatUsesCompactRows)
        // Even then the island never leaves the visible frame.
        let frame = geometry.panelFrame(for: .expanded, accessoryHeight: layout.expandedChatHeight)
        #expect(frame.minY >= tiny.visibleFrame.minY)
    }
}
