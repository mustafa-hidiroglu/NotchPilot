import NotchPilotCore
import SwiftUI

/// Design tokens. The island is always an opaque black surface, like the hardware it grows
/// out of (HIG › Live Activities: "Live Activities in the Dynamic Island use a black opaque
/// background"), so its colours are fixed dark-appearance values and contrast is constant in
/// light and dark mode. One colour, one meaning: red = capturing, teal = audio level,
/// yellow = needs attention. Every colour is paired with a symbol or text. Assistant rows
/// (AssistantViews.swift) use the same tokens; teal never appears there.
///   primary   white 92%  on #000 → 17.6:1
///   secondary white 62%  on #000 →  8.0:1
///   live      systemRed  (#FF453A dark) on #000 → 6.2:1
///   level     systemTeal (#40C8E0 dark) on #000 → 10.6:1
/// Buttons use black labels on light fills (white-on-tint fails 4.5:1 for 13 pt text):
///   neutral   #000 on white 92% → 17.6:1        destructive  #000 on systemRed → 6.2:1
enum IslandPalette {
    static let surface = Color.black
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.62)
    /// Increase Contrast: secondary text 7.8:1 → 13.1:1.
    static let secondaryHighContrast = Color.white.opacity(0.80)
    static let idleGlyph = Color.white.opacity(0.55)
    static let live = Color(nsColor: .systemRed)
    static let level = Color(nsColor: .systemTeal)
    static let attention = Color(nsColor: .systemYellow)
    static func keyline(highContrast: Bool) -> Color { .white.opacity(highContrast ? 0.45 : 0.14) }
}

/// Capsule action button for the island: black 13 pt semibold label on a light fill,
/// 28 pt minimum height (HIG › Accessibility: macOS default control size), dimmed when
/// pressed or disabled. Teal stays reserved for the level meter.
struct IslandActionButtonStyle: ButtonStyle {
    var fill: Color = IslandPalette.primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .background(Capsule().fill(fill))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

struct IslandView: View {
    @Bindable var model: IslandViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false
    @State private var hoverTask: Task<Void, Never>?

    private var geometry: IslandGeometry { model.geometry }
    private var isExpanded: Bool { model.presentation == .expanded }

    var body: some View {
        ZStack(alignment: .top) {
            island
                // Reduce Motion: each presentation is a distinct view, so the change is a
                // cross-fade with no growth, scaling or movement (HIG › Accessibility:
                // "Replacing transitions in x-, y-, and z-axes with fades").
                .id(reduceMotion ? (isExpanded ? 1 : 0) : -1)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        // One source of truth for Reduce Motion: the view model picks its animation from it.
        .onChange(of: reduceMotion, initial: true) { _, newValue in model.reduceMotion = newValue }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchPilot")
    }

    /// Extra expanded height for assistant output; animated by the view model.
    private var accessoryHeight: CGFloat { isExpanded ? model.accessoryHeight : 0 }

    private var island: some View {
        let size = geometry.islandSize(for: model.presentation, accessoryHeight: accessoryHeight)
        let shape = IslandShape(topRadius: geometry.topCornerRadius(for: model.presentation),
                                bottomRadius: geometry.bottomCornerRadius(for: model.presentation),
                                shoulderRadius: geometry.shoulderRadius)

        return ZStack(alignment: .top) {
            shape.fill(IslandPalette.surface)
            if !geometry.attachedToNotch {
                // Key line separates a floating island from dark wallpapers (HIG › Live Activities).
                shape.stroke(IslandPalette.keyline(highContrast: contrast == .increased), lineWidth: 1)
            }
            VStack(spacing: 0) {
                header
                if isExpanded {
                    let expanded = geometry.islandSize(for: .expanded, accessoryHeight: model.accessoryHeight)
                    ExpandedContent(model: model)
                        // Laid out at its final width and height from the first frame, so text
                        // never re-wraps while the island grows; the clip shape reveals it.
                        .frame(width: expanded.width - 2 * model.config.layout.contentInset,
                               height: max(0, expanded.height - geometry.headerHeight - model.config.layout.contentInset),
                               alignment: .topLeading)
                        .padding(.horizontal, model.config.layout.contentInset)
                        .padding(.bottom, model.config.layout.contentInset)
                        .transition(contentTransition)
                }
            }
            .padding(.horizontal, geometry.shoulderRadius)
        }
        .frame(width: size.width + 2 * geometry.shoulderRadius, height: size.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(isExpanded ? 0.35 : 0), radius: 12, y: 6)
        .onHover(perform: hoverChanged)   // the island only, not the transparent shadow margin
    }

    /// Expanded content settles in with a slight scale from the top edge, following the
    /// island's own growth direction (only used when Reduce Motion is off).
    private var contentTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
    }

    // MARK: Header — identical in both presentations, so expanding only moves it outward.

    private var header: some View {
        Button(action: model.toggleExpanded) {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    CaptureGlyph(state: model.captureState)
                    if model.hasReplyWhileCollapsed {
                        // A reply finished while collapsed; cleared when it's dismissed.
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(IslandPalette.primary)
                            .accessibilityLabel("Reply ready")
                            .transition(.opacity)
                    }
                }
                .frame(width: model.config.layout.compactWingWidth)
                Spacer(minLength: 0)
                if !geometry.attachedToNotch {
                    Text("NotchPilot")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IslandPalette.secondary)
                    Spacer(minLength: 0)
                }
                MiniMeter(level: model.level.normalizedLevel, active: isRunning)
                    .frame(width: model.config.layout.compactWingWidth)
            }
            .frame(height: geometry.headerHeight)
            .opacity(isHovering || isExpanded ? 1 : 0.85)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(headerAccessibilityLabel)
        .accessibilityHint(isExpanded ? "Collapses the island" : "Expands the island to show capture controls")
    }

    private var isRunning: Bool {
        if case .running = model.captureState { return true }
        return false
    }

    private var headerAccessibilityLabel: String {
        let status = switch model.captureState {
        case .idle: "capture off"
        case .starting: "starting capture"
        case .running: "capturing system audio"
        case .stopping: "stopping capture"
        case .failed(let error): error.title
        }
        return model.hasReplyWhileCollapsed ? "NotchPilot, \(status), reply ready" : "NotchPilot, \(status)"
    }

    // MARK: Hover expansion (optional, off by default)

    private func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        guard model.config.features.expandOnHover else { return }
        hoverTask?.cancel()
        if hovering {
            let delay = model.config.animation.hoverExpandDelay
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                model.setPresentation(.expanded)
            }
        } else if isExpanded {
            model.setPresentation(.compact)
        }
    }
}

// MARK: - Components

/// Leading glyph. Shape and colour both carry the state, so it is readable without colour.
private struct CaptureGlyph: View {
    let state: CaptureState

    var body: some View {
        Group {
            switch state {
            case .idle:
                Image(systemName: "waveform")
                    .foregroundStyle(IslandPalette.idleGlyph)
            case .starting, .stopping:
                ProgressView().controlSize(.mini)
            case .running:
                // A red waveform rather than a bare dot, so it can't be mistaken for macOS's
                // own recording indicator.
                Image(systemName: "waveform")
                    .foregroundStyle(IslandPalette.live)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(IslandPalette.attention)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .accessibilityHidden(true)
    }
}

/// Four-bar level meter for the trailing wing. Bars have fixed, distinct weights so the
/// meter reads as a waveform without random motion.
private struct MiniMeter: View {
    let level: Float
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let weights: [CGFloat] = [0.55, 1.0, 0.75, 0.4]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(active ? IslandPalette.level : IslandPalette.idleGlyph.opacity(0.6))
                    .frame(width: 3, height: barHeight(weights[index]))
            }
        }
        .frame(height: 14)
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: displayedLevel)
        .accessibilityHidden(true)
    }

    /// Reduce Motion: no interpolation and only four discrete steps, so the meter changes
    /// rarely instead of moving continuously next to the menu bar.
    private var displayedLevel: Float {
        let clamped = min(max(level, 0), 1)
        return reduceMotion ? (clamped * 4).rounded() / 4 : clamped
    }

    private func barHeight(_ weight: CGFloat) -> CGFloat {
        guard active else { return 3 }
        return 3 + 11 * weight * CGFloat(displayedLevel)
    }
}

/// Expanded body: status, primary action, level meter, live transcript, Ask row, assistant
/// output, telemetry and privacy note.
private struct ExpandedContent: View {
    @Bindable var model: IslandViewModel
    @FocusState private var primaryFocused: Bool
    @FocusState private var questionFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    private var secondary: Color {
        contrast == .increased ? IslandPalette.secondaryHighContrast : IslandPalette.secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IslandPalette.primary)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(technicalDetail)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                primaryAction
            }

            LevelBar(snapshot: model.level, active: isRunning)

            TranscriptRow(model: model)

            AskRow(model: model, questionFocused: $questionFocused)
                // Global Ask shortcut: the panel is already key; move focus into the field.
                .onChange(of: model.wantsQuestionFocus, initial: true) { _, wants in
                    guard wants else { return }
                    questionFocused = true
                    model.wantsQuestionFocus = false
                    // Again after this layout pass, in case the field appeared in this same
                    // update and wasn't in the window yet.
                    Task { questionFocused = true }
                }

            if model.askPhase != .idle {
                AskOutput(model: model, height: outputHeight)
                    .transition(.opacity)
            }

            HStack(spacing: 0) {
                if model.config.features.showTelemetry {
                    Text(telemetry)
                        .monospacedDigit()
                        .accessibilityLabel(telemetryAccessibility)
                }
                Spacer(minLength: 8)
                Label("Transcribed on this Mac · Sent only when you Ask", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .help("Audio, transcripts and screenshots stay in memory and are never saved. Ask sends one request to \(model.provider.displayName).")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(secondary)
            // Pinned to the bottom edge of the fixed-height content (no extra stack gap).
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var isRunning: Bool {
        if case .running = model.captureState { return true }
        return false
    }

    /// Final height of the output container (its share of the accessory height, minus the
    /// stack spacing above it).
    private var outputHeight: CGFloat {
        let layout = model.config.layout
        let accessory = model.askPhase.showsReply ? layout.expandedReplyHeight : layout.expandedNoticeHeight
        return accessory - 10
    }

    private var headline: String {
        switch model.captureState {
        case .idle: "System Audio Capture Is Off"
        case .starting: "Starting Capture…"
        case .running: "Capturing System Audio"
        case .stopping: "Stopping Capture…"
        case .failed(let error): error.title
        }
    }

    private var detail: String {
        switch model.captureState {
        case .idle: "Captures what your Mac plays, never the microphone."
        case .starting: "macOS may ask for Screen & System Audio Recording access."
        case .running(let format): format.description
        case .stopping: model.format.description
        case .failed(let error): error.message
        }
    }

    /// Raw system error text stays out of the visible message; it is available as a tooltip.
    private var technicalDetail: String {
        if case .failed(let error) = model.captureState { return error.technicalDetail ?? "" }
        return ""
    }

    @ViewBuilder private var primaryAction: some View {
        Group {
            switch model.captureState {
            case .failed(let error) where error.offersPrivacySettings:
                Button("Open Privacy Settings", action: model.openPrivacySettings)
                    .buttonStyle(IslandActionButtonStyle())
                    .accessibilityHint("Opens Privacy & Security settings for Screen & System Audio Recording")
            case .running, .starting:
                Button(action: model.toggleCapture) { Label("Stop Capture", systemImage: "stop.fill") }
                    .buttonStyle(IslandActionButtonStyle(fill: IslandPalette.live))
            case .stopping:
                Button(action: {}) { Label("Stop Capture", systemImage: "stop.fill") }
                    .buttonStyle(IslandActionButtonStyle(fill: IslandPalette.live))
                    .disabled(true)
            case .idle, .failed:
                Button(action: model.toggleCapture) { Label("Start Capture", systemImage: "record.circle") }
                    .buttonStyle(IslandActionButtonStyle())
            }
        }
        // Return triggers the primary action when the panel is key ("Show Controls"), and
        // keyboard focus lands on it so Space works too. While the question field has focus,
        // Return belongs to the field (it asks).
        .keyboardShortcut(questionFocused ? nil : .defaultAction)
        .focused($primaryFocused)
        .onAppear { if !model.wantsQuestionFocus { primaryFocused = true } }
    }

    private var telemetry: String {
        let stats = model.level.statistics
        return "Dropped \(stats.framesDropped) · Rejected \(stats.framesRejected)"
    }

    private var telemetryAccessibility: String {
        let stats = model.level.statistics
        return "\(stats.framesDropped) frames dropped, \(stats.framesRejected) frames rejected"
    }
}

/// Horizontal RMS meter with peak tick and dB readout.
private struct LevelBar: View {
    let snapshot: LevelSnapshot
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let level = CGFloat(active ? snapshot.normalizedLevel : 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(IslandPalette.level).frame(width: max(6, width * level))
                        .opacity(active ? 1 : 0)
                }
            }
            .frame(height: 6)
            Text(active ? String(format: "%.0f dB", snapshot.rmsDecibels) : "– dB")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(IslandPalette.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: snapshot.rms)
        .accessibilityElement()
        .accessibilityLabel("System audio level")
        .accessibilityValue(active ? String(format: "%.0f decibels", snapshot.rmsDecibels) : "Not capturing")
    }
}
