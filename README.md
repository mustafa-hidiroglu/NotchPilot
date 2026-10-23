# NotchPilot

NotchPilot is a macOS menu-bar utility with a Dynamic-Island-inspired panel at the top of the primary display. When you start it, it captures system audio (what your Mac plays, not the microphone) through ScreenCaptureKit and passes the samples through a C++20 lock-free single-producer/single-consumer (SPSC) ring buffer to a non-real-time consumer that measures levels for the island's meter. Capture is off until you turn it on. NotchPilot is not affiliated with Apple and does not imitate system UI; the island is its own opaque black panel.

- [Prerequisites](#prerequisites)
- [Build, run, test](#build-run-test)
- [Project layout](#project-layout)
- [Architecture](#architecture)
- [Audio format and real-time contract](#audio-format-and-real-time-contract)
- [Window behaviour](#window-behaviour)
- [Configuration](#configuration)
- [Permissions and privacy](#permissions-and-privacy)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## Prerequisites

| Requirement | Detail |
|---|---|
| macOS | 14 or later (`platforms: [.macOS(.v14)]`) |
| Toolchain | Xcode 16+ / Swift 6.0+ with Swift/C++ interoperability (available since Swift 5.9) |
| Verified with | Xcode 27.0, Swift 6.4, macOS (arm64) |

`Package.swift` uses `// swift-tools-version: 6.0`, so older toolchains fail with a clear message.

**C++ interoperability.** `NotchPilotCore`, `NotchPilot` and the test target enable `.interoperabilityMode(.Cxx)` (shared through `swiftCommon` in `Package.swift`). Every Swift target that imports `NPRingBuffer` needs it. If interop is off, `Sources/NPRingBuffer/include/NPRingBuffer.h` stops the build with this `#error`:

```
NPRingBuffer.h must be compiled as C++. Enable Swift C++ interoperability: SwiftPM `.interoperabilityMode(.Cxx)` or Xcode 'C++ and Objective-C Interoperability' = 'C++ / Objective-C++' (-cxx-interoperability-mode=default).
```

If you add the sources to an Xcode project, set **C++ and Objective-C Interoperability** to **C++ / Objective-C++** on every Swift target that imports `NPRingBuffer`.

## Build, run, test

Scripts (`scripts/`):

```sh
scripts/build.sh            # release build, assembles and signs NotchPilot.app
scripts/build.sh --debug    # debug build (enables the C++ ownership asserts)
scripts/build.sh --run      # build, then launch the app
scripts/build.sh --help
scripts/test.sh             # swift test + C++ tests under TSan and ASan/UBSan
scripts/test.sh --cpp-only  # C++ tests only
```

`scripts/build.sh` signs ad hoc by default. Set `CODESIGN_IDENTITY` to a stable identity (see [Troubleshooting](#troubleshooting)):

```sh
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/build.sh --run
```

`Resources/Info.plist` sets `LSUIElement` (no Dock icon), bundle identifier `app.notchpilot.NotchPilot`, and no usage-description keys.

Raw SwiftPM equivalents:

```sh
swift build                 # debug
swift build -c release
swift run NotchPilot        # runs the bare executable (no app bundle)
swift test                  # Swift tests (NotchPilotCoreTests)
```

`swift run` works for UI work because `main.swift` sets the `.accessory` activation policy itself. For a stable TCC identity use the bundled app from `scripts/build.sh`.

**Why SwiftPM instead of an `.xcodeproj`.** The project builds reproducibly from the command line with no project generator (xcodegen was not available), the C++ target, interop flag and C++20 standard are declared in one reviewable `Package.swift`, and there is no generated project file to keep in sync. The `.app` bundle is assembled by `scripts/build.sh`.

## Project layout

```
Package.swift
Resources/Info.plist             LSUIElement, bundle id, no usage keys
scripts/build.sh, test.sh
Sources/
  NPRingBuffer/                  C++20 target
    include/NPRingBuffer.h       only surface Swift imports (opaque NPRing* + np_ring_* functions)
    SPSCRingBuffer.hpp           np::SPSCRingBuffer<Sample> template
    NPRingBuffer.cpp             bridge implementation
  NotchPilotCore/                Swift 6 + C++ interop, no AppKit UI
    Config/NotchPilotConfig.swift
    Geometry/IslandGeometry.swift     pure layout math (DisplayMetrics, IslandPresentation)
    Audio/AudioCaptureService.swift   actor: SCStream lifecycle, CaptureState
    Audio/AudioStreamSink.swift       SCStreamOutput on the sample queue (real-time producer)
    Audio/PCMConverter.swift          CMSampleBuffer -> interleaved Float32
    Audio/RingBuffer.swift            ~Copyable RingProducer / RingConsumer over NPRing
    Audio/AudioPipelineConsumer.swift timer-driven drain, levels, AsyncStream output
    Audio/CaptureError.swift
  NotchPilot/                    AppKit/SwiftUI executable
    App/main.swift, AppDelegate.swift
    MenuBar/StatusItemController.swift
    Panel/NotchPanel.swift, IslandPanelController.swift
    Island/IslandViewModel.swift, IslandView.swift, IslandShape.swift
Tests/
  NotchPilotCoreTests/           Swift Testing
  cpp/ring_buffer_tests.cpp      standalone C++ tests (no framework)
```

## Architecture

### Data flow

```mermaid
flowchart LR
    SCK["SCStream<br/>(system audio)"] -->|"CMSampleBuffer<br/>sample queue, user-interactive"| SINK["AudioStreamSink"]
    SINK --> CONV["PCMConverter<br/>copy + interleave"]
    CONV -->|"np_ring_write"| RING[("C++ SPSC ring<br/>NPRing")]
    RING -->|"np_ring_read<br/>timer queue, every 10 ms"| CONS["AudioPipelineConsumer<br/>RMS / peak"]
    CONS -->|"AsyncStream&lt;LevelSnapshot&gt;<br/>newest wins"| VM["IslandViewModel<br/>@MainActor"]
    SVC["AudioCaptureService<br/>(actor)"] -->|"AsyncStream&lt;CaptureState&gt;"| VM
    VM --> VIEW["IslandView"]
    VIEW --> PANEL["NotchPanel"]
```

Format problems found on the real-time path do not call out: the sink records them in the ring's reject counters, and the consumer polls them and notifies `AudioCaptureService`.

### Capture state machine

`CaptureState` in `AudioCaptureService.swift`:

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> starting: start()
    starting --> running: startCapture succeeded
    starting --> failed: no permission, no display,<br/>allocation or stream error
    running --> stopping: stop() / unsupported format
    running --> failed: stream stopped by system
    stopping --> idle: clean shutdown
    stopping --> failed: shutdown error / unsupported format
    failed --> starting: start()
    failed --> idle: stop()
```

`start()` is ignored while the state is `starting`, `running` or `stopping`. `start()` and `stop()` are serialised through a task chain. Pressing Stop while starting also sets a cancellation flag that `performStart` checks after every suspension point, so a start in progress is abandoned (and a stream that already started is torn down) instead of capturing first.

### Threading and isolation

| Component | Runs on | Notes |
|---|---|---|
| `AudioCaptureService` | its own actor | Owns `SCStream`, `Session` (stream, sink, consumer), state. Never on the real-time path. |
| `AudioStreamSink`, `PCMConverter` | serial queue `app.notchpilot.audio-capture` (`.userInteractive`) | Real-time producer. No allocation, locks, logging, actor hops or UI work. |
| C++ ring | any thread | One producer side, one consumer side; atomics only. |
| `AudioPipelineConsumer` | serial queue `app.notchpilot.audio-consumer` (`.userInitiated`) | `DispatchSourceTimer` (non-blocking), drains full blocks, vDSP RMS/peak. |
| `IslandViewModel`, `IslandView`, `NotchPanel`, `IslandPanelController`, `StatusItemController`, `AppDelegate` | `@MainActor` | Only receive bounded `AsyncStream` values; never touched by audio threads. |

`states` is `bufferingNewest(8)`; `levels` is `bufferingNewest(1)`.

### Audited `@unchecked Sendable` boundaries

| Type | Invariant (from the code comments) |
|---|---|
| `RingStorage` (`RingBuffer.swift`) | Only mutable state lives behind the C++ atomics; Swift stored properties are immutable. It owns the `NPRing` and destroys it in `deinit`. Producer and consumer hold strong references, so the C++ object outlives every caller, including a late capture callback racing teardown. |
| `RingProducer`, `RingConsumer` (`RingBuffer.swift`) | `~Copyable`, so a handle has one owner. `RingBuffer.init` creates exactly one of each, which enforces SPSC in the type system. Moving a handle to the queue that uses it is the intended use; the C++ side synchronises with acquire/release atomics. |
| `AudioStreamSink` (`AudioStreamSink.swift`) | `converter` and `producer` are used only inside `stream(_:didOutputSampleBuffer:of:)`, which ScreenCaptureKit calls serially on `sampleQueue`. All other stored properties are immutable. The sink never references UI objects. |
| `AudioPipelineConsumer` (`AudioPipelineConsumer.swift`) | Every mutable property is read and written only on its `queue` (asserted with `dispatchPrecondition` in debug builds). `start()` and `stop()` hop onto the queue themselves. |

`AudioCaptureService` additionally holds `processor` as `nonisolated(unsafe) weak var`; `PCMBlockProcessor` is `AnyObject, Sendable`.

## Audio format and real-time contract

**Published format.** Float32, native endian, interleaved, 48 kHz, 2 channels by default (`NotchPilotConfig.Audio`). `PCMFormat.description` renders it as `48 kHz · Stereo · Float32`.

**Conversion rules** (`PCMConverter`):

- Mono source: the sample is duplicated to every output channel.
- Stereo source to mono output: the first two channels are averaged.
- Source channels beyond the output count are ignored (a guard, not a mixer).
- No resampling. A source whose sample rate differs from the configured rate by 0.5 Hz or more is rejected (`sampleRateMismatch`).
- Rejection policy: structural problems (`notLinearPCM`, `notFloat32` incl. big-endian or non-packed, `sampleRateMismatch`, `tooManyChannels`) stop capture with "Unsupported Audio Format". Per-buffer problems (`bufferTooLarge`, `copyFailed`, `missingFormat`) are only counted in `framesRejected`; capture continues.
- Rejected inputs (counted in `framesRejected`, reason in `lastRejectReason`): not linear PCM, not 32-bit float, more than 8 channels, sample-rate mismatch, buffer larger than `maxFramesPerCallback`, copy failure, missing format description. The consumer sees a rejection and capture stops with `CaptureError.unsupportedFormat`.

**Buffer lifetime.** Audio is copied out of the `CMSampleBuffer` with `CMSampleBufferCopyPCMDataIntoAudioBufferList` into converter-owned scratch memory preallocated in `init` (input scratch for up to 8 channels, plus an interleaved output block). No pointer into a framework-owned buffer outlives the callback that delivered it.

**Ring buffer** (`SPSCRingBuffer.hpp`):

- Capacity is rounded up to a power of two so the index is a single AND. The default request is `1 << 15` frames (about 0.68 s at 48 kHz). Maximum is `1 << 24` frames.
- `head_` (producer) and `tail_` (consumer) are 64-bit monotonic counters on separate cache lines. Each side publishes with a release store after touching sample memory and observes the other side with an acquire load.
- `static_assert` requires lock-free 64-bit atomics on the target.
- `write()` and `read()` do no allocation, locking, system calls or logging.
- **Overflow:** `write()` stores the frames that fit, drops the newest remainder, and counts `framesDropped` and `overflowEvents`. Old audio is never overwritten.
- **Underrun:** `read()` returns fewer frames than requested when not enough are buffered and counts an `underrunEvents`. It never blocks or pads. The consumer reads only full blocks (`consumerBlockFrames`), so its own polling does not cause underruns.
- **Debug ownership asserts:** debug builds define `NP_RING_DEBUG_OWNERSHIP=1`, which asserts that no second producer or consumer enters concurrently. The C++ test binary also uses it.
- `RingProducer` and `RingConsumer` are `~Copyable` handles over a shared `RingStorage`.

**Teardown order** (`AudioCaptureService.teardown`):

1. Stop the stream (`SCStream.stopCapture`; "already stopped" is ignored).
2. Remove the audio output.
3. `AudioStreamSink.drainCallbacks()` waits for callbacks already queued on `sampleQueue`.
4. `AudioPipelineConsumer.stop()` cancels the timer, drains remaining frames (including the final partial block, read exactly so it is not counted as an underrun) and yields a final snapshot.
5. Release the session; `RingStorage.deinit` destroys the ring.

`AppDelegate.applicationShouldTerminate` stops active capture before quitting.

## Window behaviour

### `NotchPanel` settings

| Setting | Value |
|---|---|
| Style mask | `.borderless`, `.nonactivatingPanel` |
| `isFloatingPanel` | `true` |
| `level` | `.statusBar` |
| `collectionBehavior` | `.canJoinAllSpaces`, `.stationary`, `.ignoresCycle`; plus `.fullScreenAuxiliary` if `showOverFullScreenApps` |
| `hidesOnDeactivate` | `false` |
| `becomesKeyOnlyIfNeeded` | `true` |
| `isReleasedWhenClosed` | `false` |
| `sharingType` | `.none` when `excludeFromScreenSharing` (best effort, see [privacy](#permissions-and-privacy)) |
| Also | `canBecomeKey = true`, `canBecomeMain = false`, not movable, no window animation, transparent background, accessibility role `.popover`, label "NotchPilot" |

### Placement and resizing

- The island is placed on `NSScreen.screens.first` (the primary display).
- **Notch-attached:** when `attachToNotch` is on and the display reports a camera housing (`safeAreaInsets.top` and the auxiliary top areas), the island is flush with the physical top edge, has square top corners and concave shoulders, and is sized to the notch width plus a wing on each side.
- **Floating:** on displays without a notch, a capsule of `compactSizeWithoutNotch` sits `floatingTopMargin` below the menu bar, rounded on all corners, with a thin key line.
- **Grow before expand, shrink after collapse.** The panel frame is set to the target size before the expand animation starts and shrinks only after the collapse animation completes (`presentationWillChange` / `presentationDidSettle`). The window never animates; SwiftUI animates the island inside it. In the compact resting state the panel covers only the island. A newer transition retargets the running one, and only the latest completion resizes the panel.
- **Display changes:** `NSApplication.didChangeScreenParametersNotification` recomputes geometry and the panel frame.

### Interaction

| Input | Result |
|---|---|
| Click the island header | Expand or collapse |
| Escape (while the panel is key) | Collapse. Only "Show Controls" in the menu makes the non-activating panel key (NotchPilot is not activated); clicks and background updates never do, and collapsing hands key status back to the frontmost app. |
| Click outside | Collapse. A global mouse-down monitor is installed only while expanded; it observes events and cannot modify or consume them. |
| Menu-bar item | Start/Stop Capture (Cmd-R in the open menu), Show Controls, Show/Hide Island, Open Privacy Settings, Quit |
| Hover | Expands after `hoverExpandDelay` only if `expandOnHover` is enabled (off by default) |

### Reduce Motion and accessibility

- With Reduce Motion on, the springs are replaced by an `easeInOut` of `reducedMotionFade` seconds and content fades without scaling.
- The header button is labelled "NotchPilot, <status>" with a hint; the Start Capture / Stop Capture / Open Privacy Settings buttons (black labels on light capsules, ≥ 6.2:1) and the level bar have labels and values; Return triggers the primary button after "Show Controls"; failures are announced to VoiceOver even while collapsed; telemetry has a spoken form; the status item has an accessibility label.
- The state glyph pairs colour with shape (red waveform while capturing, spinner, warning triangle, grey waveform when idle). With Reduce Motion on, the meters stop animating and move in four discrete steps. The status item uses a distinct filled symbol while capturing.

### Design tokens (`IslandPalette`)

The island is always an opaque black surface with fixed dark-appearance colours. Ratios below are the values documented in `IslandView.swift`, against `#000`:

| Token | Value | Contrast |
|---|---|---|
| `primary` | white 92% | 18.9:1 |
| `secondary` | white 62% | 8.0:1 |
| `live` (capturing) | `systemRed` | 5.6:1 |
| `level` (audio level) | `systemTeal` | 10.6:1 |
| `attention` | `systemYellow` | not listed in source |
| `idleGlyph` | white 55% | not listed in source |
| `keyline` | white 14% (45% with Increase Contrast) | n/a |

## Configuration

All tunables live in `NotchPilotConfig` (`Sources/NotchPilotCore/Config/NotchPilotConfig.swift`). They are compile-time defaults: edit and rebuild. `AppDelegate` uses `NotchPilotConfig.default`.

### `layout`

| Field | Default | Meaning |
|---|---|---|
| `compactWingWidth` | 40 | Width of each side wing flanking the camera housing in compact state |
| `compactSizeWithoutNotch` | 200 x 32 | Compact size on displays without a camera housing |
| `minimumNotchHeight` | 32 | Fallback compact height if a notched display reports no safe-area inset |
| `expandedContentSize` | 440 x 132 | Expanded content area, measured below the housing / top edge |
| `compactCornerRadius` | 12 | Bottom corner radius, compact |
| `expandedCornerRadius` | 24 | Bottom corner radius, expanded |
| `shoulderRadius` | 8 | Concave shoulder radius where a notch-attached island meets the menu bar |
| `floatingTopMargin` | 6 | Gap between the menu bar and a floating island |
| `shadowMargin` | 18 | Transparent margin so the shadow is not clipped |
| `contentInset` | 14 | Inset that keeps content concentric with the rounded edge |

### `animation`

| Field | Default | Meaning |
|---|---|---|
| `expandResponse` | 0.42 | Spring response (seconds) when opening |
| `expandDamping` | 0.80 | Spring damping fraction when opening |
| `collapseResponse` | 0.34 | Spring response when closing |
| `collapseDamping` | 0.92 | Spring damping fraction when closing |
| `reducedMotionFade` | 0.18 | Cross-fade duration (seconds) used with Reduce Motion |
| `hoverExpandDelay` | 0.35 | Seconds the pointer must rest before hover expansion |
| `meterRefreshHz` | 20 | Level meter publish rate (Hz) |

### `audio`

| Field | Default | Meaning |
|---|---|---|
| `sampleRate` | 48000 | Published sample rate; other source rates are rejected |
| `channelCount` | 2 | Published channel count |
| `ringCapacityFrames` | 32768 (`1 << 15`) | Ring capacity request; rounded up to a power of two |
| `maxFramesPerCallback` | 8192 | Largest buffer accepted per callback; larger ones are rejected, not allocated for |
| `consumerBlockFrames` | 1024 | Block size the consumer drains and analyses (minimum 64) |
| `consumerInterval` | 0.010 | Consumer timer interval in seconds (minimum 0.002) |
| `excludesCurrentProcessAudio` | `true` | Exclude NotchPilot's own audio from capture |

### `features`

| Field | Default | Meaning |
|---|---|---|
| `expandOnHover` | `false` | Expand when the pointer rests on the island |
| `attachToNotch` | `true` | Attach to the camera housing on displays that have one |
| `showOverFullScreenApps` | `false` | Add `.fullScreenAuxiliary` so the island appears over full-screen apps |
| `excludeFromScreenSharing` | `true` | Set `NSWindow.sharingType = .none` |
| `showTelemetry` | `false` | Diagnostic: show dropped and rejected frame counts in the expanded island |

## Permissions and privacy

- **Off by default.** The app launches with capture idle. Capture starts only when you choose Start (island or menu).
- **Visible indicators** while capturing: a red waveform glyph in the island (compact and expanded), the filled `waveform.circle.fill` status-item symbol, and macOS's own system recording indicator.
- **Stop is always available** in the island (while starting or running) and in the menu ("Stop Capture").
- **Audio only.** No `.screen` output is registered, so video frames are never delivered to NotchPilot.
- **Microphone excluded** (`captureMicrophone = false` on macOS 15+; system audio only).
- **Own audio excluded** (`excludesCurrentProcessAudio`, on by default).
- **Nothing is written to disk or sent over the network.** There is no analytics. Audio exists only in the in-memory ring and is analysed for level and counters. The island says "In memory only, never saved".
- **`sharingType = .none` is best effort, not a guarantee.** It asks the window server to exclude the panel from window sharing and capture. Recent macOS versions ignore it for ScreenCaptureKit-based capture (which is what most current screen recorders and sharing apps use), so treat it as a courtesy flag for older capture paths only.

**Permission flow.** Starting capture lists shareable content, which triggers macOS's Screen & System Audio Recording prompt. If access is denied, the island shows "Permission Needed" with an **Open Privacy Settings** button, and the menu offers the same item. Manual path: System Settings > Privacy & Security > Screen & System Audio Recording, enable NotchPilot, then start capture again. macOS may periodically ask you to re-confirm this permission.

## Known limitations

- The interactive capture and permission (TCC) flow needs a human on a Mac; it is not covered by automated tests.
- With ad-hoc signing the code identity changes on every rebuild, so macOS may ask for permission again.
- ScreenCaptureKit requires a display content filter to deliver system audio, so a 2x2 px, at most 1 fps video stream exists. NotchPilot registers no screen output and discards that video.
- No resampling: audio whose sample rate differs from `audio.sampleRate` is rejected and capture stops.
- Primary display only: the island is placed on `NSScreen.screens.first`, and capture uses the main display (`CGMainDisplayID()`, falling back to the first available display).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Permission keeps being requested or denied after rebuilds | Reset the grant: `tccutil reset ScreenCapture app.notchpilot.NotchPilot`. Then build with a stable identity (`CODESIGN_IDENTITY=...`) so the grant survives rebuilds. |
| Build fails with the `NPRingBuffer.h must be compiled as C++` error | Enable C++ interop on the target (`.interoperabilityMode(.Cxx)`, or the Xcode setting under [Prerequisites](#prerequisites)). |
| Island is hidden over a full-screen app | Set `features.showOverFullScreenApps = true` in `NotchPilotConfig` and rebuild. |
| Console shows "stream output NOT found" | Log noise from ScreenCaptureKit, since NotchPilot registers only an audio output. |
| Island is missing from the menu bar area | Use the status item > Show Island. |

## License

MIT. See `LICENSE`.
