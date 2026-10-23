import Foundation
import ScreenCaptureKit
import Testing
@testable import NotchPilotCore

private let allErrors: [CaptureError] = [
    .permissionDenied,
    .audioSourceUnavailable("no display"),
    .unsupportedFormat("not 32-bit float samples"),
    .streamFailed("stream stopped"),
    .shutdownFailed("timeout"),
    .resourceAllocationFailed,
]

@Suite("CaptureError")
struct CaptureErrorTests {

    @Test("every case has a non-empty title and message", arguments: allErrors)
    func hasWording(error: CaptureError) {
        #expect(!error.title.isEmpty)
        #expect(!error.message.isEmpty)
    }

    @Test("only permissionDenied offers the privacy settings shortcut", arguments: allErrors)
    func privacyShortcut(error: CaptureError) {
        #expect(error.offersPrivacySettings == (error == .permissionDenied))
    }

    @Test("SCStreamError.userDeclined maps to permissionDenied")
    func userDeclinedMapsToPermissionDenied() {
        #expect(SCStreamError.userDeclined.rawValue == -3801)
        let declined = NSError(domain: SCStreamErrorDomain, code: -3801)
        #expect(AudioCaptureService.mapStreamError(declined) == .permissionDenied)
    }

    @Test("other errors map to streamFailed with their description")
    func otherErrorsMapToStreamFailed() {
        let other = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        #expect(AudioCaptureService.mapStreamError(other) == .streamFailed("boom"))
    }

    @Test("a different SCStream error code is not treated as a permission problem")
    func otherStreamCodeIsStreamFailed() {
        let failed = NSError(domain: SCStreamErrorDomain, code: SCStreamError.failedToStart.rawValue)
        guard case .streamFailed = AudioCaptureService.mapStreamError(failed) else {
            Issue.record("expected streamFailed"); return
        }
    }

    @Test("a CaptureError passes through unchanged")
    func captureErrorPassesThrough() {
        #expect(AudioCaptureService.mapStreamError(CaptureError.resourceAllocationFailed) == .resourceAllocationFailed)
    }
}
