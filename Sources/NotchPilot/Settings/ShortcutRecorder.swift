import AppKit
import NotchPilotCore
import Observation
import SwiftUI

/// Click to record, press a key combination, Esc to cancel. The combination is checked
/// (HotKey.problem) before it replaces the current one; a refused combination keeps the
/// recorder listening and says why underneath.
struct ShortcutRecorder: View {
    @Binding var hotKey: HotKey
    /// Called with true when listening starts and false when it ends, so the registered
    /// global shortcut can step aside while the person presses it.
    var onRecordingChange: (Bool) -> Void
    @State private var listener = KeyComboListener()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            recorderButton
            .accessibilityLabel("Ask shortcut")
            .accessibilityValue(listener.isListening ? "Recording" : hotKey.localizedSpoken)
            .accessibilityHint(listener.isListening
                               ? "Press the new key combination, or Escape to cancel"
                               : "Records a new shortcut")
            if listener.isListening {
                Group {
                    if let problem = listener.problem {
                        ErrorLabel(problem.message, textStyle: .secondary)
                    } else {
                        Text("Press Esc to cancel.").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .multilineTextAlignment(.trailing)
            }
        }
        .onDisappear { stop() }
        .onChange(of: listener.isListening) { _, listening in onRecordingChange(listening) }
    }

    /// Prominent while listening, so the recording state reads from more than the title.
    @ViewBuilder private var recorderButton: some View {
        let button = Button(action: toggle) {
            Text(title)
                .monospacedDigit()
                .frame(minWidth: 120)
        }
        if listener.isListening {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var title: String {
        guard listener.isListening else { return hotKey.localizedDisplay }
        return listener.heldModifiers.isEmpty ? "Type Shortcut" : listener.heldModifiers + "…"
    }

    private func toggle() {
        if listener.isListening {
            stop()
        } else {
            listener.start { recorded in hotKey = recorded }
        }
    }

    /// Also reports the end directly: after onDisappear, onChange no longer fires.
    private func stop() {
        listener.stop()
        onRecordingChange(false)
    }
}

/// Listens to key presses in this app's key window while recording. A local monitor only
/// sees events addressed to NotchPilot's own windows, never other apps' keystrokes.
@MainActor
@Observable
final class KeyComboListener {
    private(set) var isListening = false
    private(set) var problem: HotKeyProblem?
    /// Modifier glyphs currently held, shown while recording.
    private(set) var heldModifiers = ""

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var onRecord: (HotKey) -> Void = { _ in }

    func start(onRecord: @escaping (HotKey) -> Void) {
        guard !isListening else { return }
        self.onRecord = onRecord
        problem = nil
        heldModifiers = ""
        isListening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let isKeyDown = event.type == .keyDown
            let keyCode = UInt32(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let consumed = MainActor.assumeIsolated {
                self?.handle(isKeyDown: isKeyDown, keyCode: keyCode, flags: flags) ?? false
            }
            return consumed ? nil : event
        }
        // Leaving the window or the app ends recording, so the global shortcut (suspended
        // while listening) comes back.
        let center = NotificationCenter.default
        let sources: [(Notification.Name, AnyObject?)] = [(NSWindow.didResignKeyNotification, NSApp.keyWindow),
                                                          (NSApplication.didResignActiveNotification, NSApp)]
        for (name, object) in sources {
            resignObservers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        resignObservers.forEach { NotificationCenter.default.removeObserver($0) }
        resignObservers = []
        isListening = false
        heldModifiers = ""
    }

    /// Returns true when the event was used (and must not reach the window).
    private func handle(isKeyDown: Bool, keyCode: UInt32, flags: NSEvent.ModifierFlags) -> Bool {
        let modifiers = Self.carbonModifiers(flags)
        guard isKeyDown else {
            heldModifiers = HotKey(keyCode: 0, carbonModifiers: modifiers).modifierGlyphs
            return false
        }
        if keyCode == HotKey.Key.escape && modifiers == 0 {
            stop()
            return true
        }
        let candidate = HotKey(keyCode: keyCode, carbonModifiers: modifiers)
        if let problem = candidate.problem {
            self.problem = problem
            return true
        }
        stop()
        onRecord(candidate)
        return true
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= HotKey.Modifier.command }
        if flags.contains(.shift) { result |= HotKey.Modifier.shift }
        if flags.contains(.option) { result |= HotKey.Modifier.option }
        if flags.contains(.control) { result |= HotKey.Modifier.control }
        return result
    }
}
