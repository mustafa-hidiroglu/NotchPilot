import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit

/// One on-demand capture of the main display via `SCScreenshotManager`, JPEG-encoded in
/// memory. NotchPilot's own windows are excluded from the capture.
///
/// Privacy: runs only when `captureMainDisplayJPEG` is called; the image is never written
/// to disk or logged. The SCK objects stay inside the completion-handler chain, so only
/// the resulting `Data` crosses an isolation boundary.
public struct ScreenshotCapturer: ScreenshotCapturing {
    public init() {}

    public func captureMainDisplayJPEG(maxLongEdge: Int, quality: Double) async throws -> Data {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenshotError.permissionDenied }
        return try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: Self.map(error))
                    return
                }
                let mainID = CGMainDisplayID()
                guard let content,
                      let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first
                else {
                    continuation.resume(throwing: ScreenshotError.noDisplay)
                    return
                }
                let own = content.applications.filter { $0.processID == getpid() }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

                // Display size is in points; the filter's pixel scale gives the native pixel size.
                let scale = max(Double(filter.pointPixelScale), 1)
                let (width, height) = Self.scaledPixelSize(
                    width: Int((Double(display.width) * scale).rounded()),
                    height: Int((Double(display.height) * scale).rounded()),
                    maxLongEdge: maxLongEdge
                )
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.showsCursor = false
                config.capturesAudio = false

                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                    if let error {
                        continuation.resume(throwing: Self.map(error))
                    } else if let image {
                        do {
                            continuation.resume(returning: try Self.jpegData(from: image, quality: quality))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    } else {
                        continuation.resume(throwing: ScreenshotError.captureFailed("No image was returned."))
                    }
                }
            }
        }
    }

    // MARK: - Pure helpers

    /// Scales so the long edge is at most `maxLongEdge`, preserving aspect ratio. Never
    /// upscales; each side is at least 1.
    static func scaledPixelSize(width: Int, height: Int, maxLongEdge: Int) -> (Int, Int) {
        let w = max(width, 1)
        let h = max(height, 1)
        let longEdge = max(w, h)
        guard maxLongEdge >= 1, longEdge > maxLongEdge else { return (w, h) }
        let factor = Double(maxLongEdge) / Double(longEdge)
        return (
            max(Int((Double(w) * factor).rounded()), 1),
            max(Int((Double(h) * factor).rounded()), 1)
        )
    }

    static func jpegData(from image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ScreenshotError.encodingFailed }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1),
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0 else {
            throw ScreenshotError.encodingFailed
        }
        return data as Data
    }

    private static func map(_ error: Error) -> ScreenshotError {
        if let error = error as? ScreenshotError { return error }
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue {
            return .permissionDenied
        }
        if !CGPreflightScreenCaptureAccess() { return .permissionDenied }
        return .captureFailed(error.localizedDescription)
    }
}
