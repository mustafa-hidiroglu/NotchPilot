import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NotchPilotCore

@Suite("Screenshot")
struct ScreenshotTests {

    @Test("scaling", arguments: [
        (3456, 2234, 1568, 1568, 1014),   // landscape retina
        (2234, 3456, 1568, 1014, 1568),   // portrait
        (800, 600, 1568, 800, 600),       // already small: never upscaled
        (2000, 2000, 1000, 1000, 1000),   // square
        (1568, 1568, 1568, 1568, 1568),   // exactly at the limit
        (10_000, 10, 1568, 1568, 2),      // extreme aspect
        (10_000, 1, 1568, 1568, 1),       // short side clamps to 1
    ])
    func scaledPixelSize(w: Int, h: Int, limit: Int, expectedW: Int, expectedH: Int) {
        let size = ScreenshotCapturer.scaledPixelSize(width: w, height: h, maxLongEdge: limit)
        #expect(size.0 == expectedW)
        #expect(size.1 == expectedH)
    }

    @Test("JPEG encoding round-trips dimensions")
    func jpegRoundTrip() throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        let image = try #require(context.makeImage())

        let data = try ScreenshotCapturer.jpegData(from: image, quality: 0.8)
        #expect(Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF])

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 64)
        #expect(decoded.height == 32)
    }
}
