import Foundation

// Display and validation for `HotKey`, kept free of AppKit/Carbon so it can be unit tested.
// The app layer supplies the current keyboard layout's characters (`keyName` closure);
// the fallback names below are for the US layout.

extension HotKey {
    /// Carbon modifier bits, as `RegisterEventHotKey` takes them.
    public enum Modifier {
        public static let command: UInt32 = 0x0100   // cmdKey
        public static let shift: UInt32 = 0x0200     // shiftKey
        public static let option: UInt32 = 0x0800    // optionKey
        public static let control: UInt32 = 0x1000   // controlKey
        public static let all: UInt32 = command | shift | option | control
    }

    /// Virtual key codes used below (Carbon `kVK_*`).
    public enum Key {
        public static let space: UInt32 = 49
        public static let tab: UInt32 = 48
        public static let escape: UInt32 = 53
        public static let `return`: UInt32 = 36
        /// kVK_F1…kVK_F20 in order.
        public static let functionKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                    105, 107, 113, 106, 64, 79, 80, 90]
    }

    public var hasCommand: Bool { carbonModifiers & Modifier.command != 0 }
    public var hasShift: Bool { carbonModifiers & Modifier.shift != 0 }
    public var hasOption: Bool { carbonModifiers & Modifier.option != 0 }
    public var hasControl: Bool { carbonModifiers & Modifier.control != 0 }

    /// 1-based function key number (F1 = 1), or nil.
    public var functionKeyNumber: Int? {
        Key.functionKeys.firstIndex(of: keyCode).map { $0 + 1 }
    }

    /// Modifier glyphs in the order HIG › Keyboards prescribes: Control, Option, Shift, Command.
    public var modifierGlyphs: String {
        (hasControl ? "⌃" : "") + (hasOption ? "⌥" : "") + (hasShift ? "⇧" : "") + (hasCommand ? "⌘" : "")
    }

    /// e.g. "⇧⌘Space", "⌃⌥K", "F5". `keyName` maps a character key to what the current
    /// layout prints on it; return nil to use the US-layout name.
    public func displayString(keyName: (UInt32) -> String? = { _ in nil }) -> String {
        modifierGlyphs + Self.name(forKeyCode: keyCode, layoutName: keyName)
    }

    /// Spoken form for VoiceOver, e.g. "Shift Command Space".
    public func spokenString(keyName: (UInt32) -> String? = { _ in nil }) -> String {
        var parts: [String] = []
        if hasControl { parts.append("Control") }
        if hasOption { parts.append("Option") }
        if hasShift { parts.append("Shift") }
        if hasCommand { parts.append("Command") }
        parts.append(Self.spokenNames[keyCode] ?? Self.name(forKeyCode: keyCode, layoutName: keyName))
        return parts.joined(separator: " ")
    }

    static func name(forKeyCode code: UInt32, layoutName: (UInt32) -> String?) -> String {
        if let special = specialNames[code] { return special }
        if let index = Key.functionKeys.firstIndex(of: code) { return "F\(index + 1)" }
        if let name = layoutName(code), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name.uppercased()
        }
        return usLayoutNames[code] ?? "Key \(code)"
    }

    /// Keys whose name doesn't depend on the keyboard layout.
    static let specialNames: [UInt32: String] = [
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    static let spokenNames: [UInt32: String] = [
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 51: "Delete", 117: "Forward Delete", 53: "Escape",
        123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
    ]

    static let usLayoutNames: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
        40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
        32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
    ]
}

/// Why a recorded shortcut can't be used as the global Ask shortcut.
public enum HotKeyProblem: Equatable, Sendable {
    /// No Command, Option or Control (only F-keys may go without one).
    case needsModifier
    /// Esc, Return, Tab and similar keys can't be the main key.
    case reservedKey
    /// A standard macOS shortcut (HIG › Keyboards › Standard keyboard shortcuts).
    case system(String)

    public var message: String {
        switch self {
        case .needsModifier: "Include ⌘, ⌥ or ⌃ in the shortcut, or use a function key."
        case .reservedKey: "That key can’t be used for a shortcut. Try a letter, a number or Space."
        case .system(let use): "macOS uses that shortcut to \(use). Choose a different one."
        }
    }
}

extension HotKey {
    /// Checks a recorded shortcut. Returns nil when it can be registered.
    public var problem: HotKeyProblem? {
        if [Key.escape, Key.return, 76, Key.tab, 51, 117].contains(keyCode) { return .reservedKey }
        let mainModifiers = Modifier.command | Modifier.option | Modifier.control
        if carbonModifiers & mainModifiers == 0, functionKeyNumber == nil { return .needsModifier }
        if let use = Self.systemShortcuts[SystemKey(keyCode: keyCode, modifiers: carbonModifiers & Modifier.all)] {
            return .system(use)
        }
        return nil
    }

    private struct SystemKey: Hashable {
        var keyCode: UInt32
        var modifiers: UInt32
    }

    /// System-wide shortcuts from HIG › Keyboards that a global hot key would shadow.
    private static let systemShortcuts: [SystemKey: String] = {
        let c = Modifier.command, s = Modifier.shift, o = Modifier.option, k = Modifier.control
        var table: [SystemKey: String] = [
            SystemKey(keyCode: Key.space, modifiers: c): "show Spotlight",
            SystemKey(keyCode: Key.space, modifiers: o | c): "show Spotlight results",
            SystemKey(keyCode: Key.space, modifiers: k | c): "show the Character Viewer",
            SystemKey(keyCode: Key.space, modifiers: k): "switch input sources",
            SystemKey(keyCode: Key.space, modifiers: k | o): "switch input sources",
            SystemKey(keyCode: Key.tab, modifiers: c): "switch apps",
            SystemKey(keyCode: Key.tab, modifiers: s | c): "switch apps",
            SystemKey(keyCode: 50 /* ` */, modifiers: c): "switch windows",
            SystemKey(keyCode: 50, modifiers: s | c): "switch windows",
            SystemKey(keyCode: Key.escape, modifiers: o | c): "force quit apps",
            SystemKey(keyCode: 20 /* 3 */, modifiers: s | c): "take screenshots",
            SystemKey(keyCode: 20, modifiers: k | s | c): "take screenshots",
            SystemKey(keyCode: 21 /* 4 */, modifiers: s | c): "take screenshots",
            SystemKey(keyCode: 21, modifiers: k | s | c): "take screenshots",
            SystemKey(keyCode: 23 /* 5 */, modifiers: s | c): "take screenshots",
            SystemKey(keyCode: 28 /* 8 */, modifiers: o | c): "turn zoom on or off",
            SystemKey(keyCode: 12 /* Q */, modifiers: c): "quit apps",
            SystemKey(keyCode: 12, modifiers: s | c): "log out",
            SystemKey(keyCode: 12, modifiers: k | c): "lock the screen",
            SystemKey(keyCode: 4 /* H */, modifiers: c): "hide apps",
            SystemKey(keyCode: 4, modifiers: o | c): "hide other apps",
            SystemKey(keyCode: 46 /* M */, modifiers: c): "minimize windows",
            SystemKey(keyCode: 13 /* W */, modifiers: c): "close windows",
            SystemKey(keyCode: 2 /* D */, modifiers: o | c): "show or hide the Dock",
            SystemKey(keyCode: 3 /* F */, modifiers: k | c): "enter full screen",
            SystemKey(keyCode: 43 /* , */, modifiers: c): "open an app’s settings",
            SystemKey(keyCode: 47 /* . */, modifiers: c): "cancel operations",
        ]
        // Edit-menu shortcuts every text field relies on.
        for (code, use) in [(0 as UInt32, "select all"), (8, "copy"), (9, "paste"), (7, "cut"), (6, "undo")] {
            table[SystemKey(keyCode: code, modifiers: c)] = use
        }
        table[SystemKey(keyCode: 6, modifiers: s | c)] = "redo"
        // Control-F1…F7: keyboard focus shortcuts.
        for code in Key.functionKeys.prefix(7) {
            table[SystemKey(keyCode: code, modifiers: k)] = "move keyboard focus"
        }
        table[SystemKey(keyCode: Key.functionKeys[4], modifiers: c)] = "turn VoiceOver on or off"
        table[SystemKey(keyCode: Key.functionKeys[10], modifiers: 0)] = "show the desktop"
        return table
    }()
}
