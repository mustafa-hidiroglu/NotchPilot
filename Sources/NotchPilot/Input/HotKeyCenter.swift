import AppKit
import Carbon.HIToolbox
import NotchPilotCore
import Observation

/// Registers the global Ask shortcut with Carbon's `RegisterEventHotKey`. Unlike event taps
/// or `NSEvent` global key monitors, a registered hot key needs no Accessibility permission
/// and the app never sees any other keystroke.
///
/// Carbon delivers hot-key events on the main thread's run loop, so the handler hops onto
/// the main actor with `assumeIsolated`.
@MainActor
@Observable
final class HotKeyCenter {
    /// Why the shortcut isn't active, shown inline in Settings; nil when it works or is off.
    private(set) var registrationError: String?

    @ObservationIgnored var onPress: () -> Void = {}
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored private var wanted: HotKey?
    /// True while the shortcut recorder listens; the shortcut is unregistered meanwhile.
    @ObservationIgnored private(set) var isSuspended = false

    /// The shortcut is registered and will open the island.
    var isActive: Bool { hotKeyRef != nil }

    /// 'NPLT', identifies our hot key in the event.
    nonisolated static let signature: OSType = 0x4E50_4C54

    /// Registers `hotKey`, or unregisters when `enabled` is false. Replaces any earlier one.
    func update(enabled: Bool, hotKey: HotKey) {
        wanted = enabled ? hotKey : nil
        apply()
    }

    /// While the shortcut recorder listens, the current shortcut must reach it as a normal
    /// key press instead of triggering Ask.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        apply()
    }

    func invalidate() {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    fileprivate func handlePress() {
        guard hotKeyRef != nil else { return }
        onPress()
    }

    private func apply() {
        unregister()
        guard let hotKey = wanted else {
            registrationError = nil
            return
        }
        // A shortcut macOS already uses is refused before registering (Settings normally
        // prevents saving one, but stored settings may predate a rule).
        if let problem = hotKey.problem {
            registrationError = problem.message
            return
        }
        guard !isSuspended else {
            registrationError = nil   // stepping aside for the recorder is not a failure
            return
        }

        var status = installHandlerIfNeeded()
        if status == noErr {
            var ref: EventHotKeyRef?
            status = RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
            if status == noErr { hotKeyRef = ref }
        }
        registrationError = switch status {
        case noErr: nil
        case OSStatus(eventHotKeyExistsErr):
            "Another app is already using \(hotKey.localizedDisplay). Choose a different shortcut."
        default:
            "NotchPilot couldn’t use \(hotKey.localizedDisplay) (error \(status)). Choose a different shortcut."
        }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handlerRef == nil else { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Unretained: the app delegate keeps this object for the app's lifetime, and
        // `invalidate()` removes the handler.
        let userData = Unmanaged.passUnretained(self).toOpaque()
        return InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, userData, &handlerRef)
    }
}

private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { center.handlePress() }
    return noErr
}

// MARK: - Display

extension HotKey {
    /// e.g. "⇧⌘Space", with character keys named as the current keyboard layout prints them
    /// (HIG › Keyboards: let the system localize shortcuts).
    @MainActor var localizedDisplay: String { displayString(keyName: KeyboardLayout.character(for:)) }

    @MainActor var localizedSpoken: String { spokenString(keyName: KeyboardLayout.character(for:)) }

    /// The same shortcut as an `NSMenuItem` key equivalent, so the status menu can show it
    /// right-aligned like any other shortcut; nil for keys a menu can't display.
    @MainActor var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        var modifiers: NSEvent.ModifierFlags = []
        if hasControl { modifiers.insert(.control) }
        if hasOption { modifiers.insert(.option) }
        if hasShift { modifiers.insert(.shift) }
        if hasCommand { modifiers.insert(.command) }
        let arrows: [UInt32: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
                                     125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey]
        let key: String
        if keyCode == Key.space {
            key = " "
        } else if let number = functionKeyNumber, let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) {
            key = String(Character(scalar))
        } else if let arrow = arrows[keyCode], let scalar = UnicodeScalar(arrow) {
            key = String(Character(scalar))
        } else if let character = KeyboardLayout.character(for: keyCode)?.lowercased(),
                  character.count == 1, !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            key = character
        } else {
            return nil
        }
        return (key, modifiers)
    }
}

/// What the current keyboard layout prints on a key, via Text Input Sources.
@MainActor
enum KeyboardLayout {
    static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                                        characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}
