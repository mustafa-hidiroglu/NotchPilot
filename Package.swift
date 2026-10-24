// swift-tools-version: 6.0
// NotchPilot — macOS 14+ menu-bar utility with a Dynamic-Island-inspired panel and
// ScreenCaptureKit system-audio capture feeding a C++20 lock-free ring buffer.
//
// Toolchain requirements (checked again by scripts/build.sh):
//   * Swift 6.0+ (tools version above fails clearly on older toolchains)
//   * Swift/C++ interoperability (`.interoperabilityMode(.Cxx)`), available since Swift 5.9
//   * Xcode 16+ / macOS 14+ SDK for ScreenCaptureKit audio capture
//
// Every Swift target that imports a module built with C++ interop must enable it too,
// so the setting is shared through `swiftCommon`.

import PackageDescription

// Strict concurrency: `swiftLanguageModes: [.v6]` below makes complete checking (and data-race
// errors) mandatory for every Swift target; no extra flag is needed.
let swiftCommon: [SwiftSetting] = [
    .interoperabilityMode(.Cxx),
]

let package = Package(
    name: "NotchPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchPilot", targets: ["NotchPilot"]),
    ],
    targets: [
        // whisper.cpp (on-device speech-to-text), built from pinned upstream source by
        // scripts/build-whisper.sh (tag v1.9.5, commit verified) as a static, universal
        // library. Static linking keeps the app free of third-party dylibs, so library
        // validation stays on. scripts/build.sh and scripts/test.sh create it when missing.
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        // C++20 real-time primitives. Public surface: include/NPRingBuffer.h only.
        .target(
            name: "NPRingBuffer",
            path: "Sources/NPRingBuffer",
            cxxSettings: [
                // Debug builds assert the single-producer / single-consumer contract at runtime.
                // (Warnings-as-errors for this code run in scripts/test.sh, which keeps the
                // package free of unsafeFlags.)
                .define("NP_RING_DEBUG_OWNERSHIP", to: "1", .when(configuration: .debug)),
            ]
        ),
        // Platform logic without AppKit UI: configuration, geometry, PCM conversion,
        // ring-buffer wrapper, ScreenCaptureKit capture, the non-real-time consumer and
        // whisper.cpp transcription.
        .target(
            name: "NotchPilotCore",
            dependencies: ["NPRingBuffer", "whisper"],
            path: "Sources/NotchPilotCore",
            swiftSettings: swiftCommon
        ),
        // AppKit/SwiftUI application: status item, NSPanel island, view model.
        .executableTarget(
            name: "NotchPilot",
            dependencies: ["NotchPilotCore"],
            path: "Sources/NotchPilot",
            swiftSettings: swiftCommon
        ),
        .testTarget(
            name: "NotchPilotCoreTests",
            dependencies: ["NotchPilotCore", "NPRingBuffer"],
            path: "Tests/NotchPilotCoreTests",
            swiftSettings: swiftCommon
        ),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx20
)
