import Testing
@testable import NotchPilotCore

@Suite("HotKey display and validation")
struct HotKeyTests {
    private typealias M = HotKey.Modifier

    @Test("modifiers are listed Control, Option, Shift, Command")
    func modifierOrder() {
        let key = HotKey(keyCode: 40 /* K */, carbonModifiers: M.command | M.shift | M.option | M.control)
        #expect(key.displayString() == "⌃⌥⇧⌘K")
        #expect(key.spokenString() == "Control Option Shift Command K")
    }

    @Test("special keys and function keys have fixed names")
    func specialKeys() {
        #expect(HotKey(keyCode: HotKey.Key.space, carbonModifiers: M.shift | M.command).displayString() == "⇧⌘Space")
        #expect(HotKey(keyCode: 96, carbonModifiers: 0).displayString() == "F5")
        #expect(HotKey(keyCode: 126, carbonModifiers: M.option).displayString() == "⌥↑")
        #expect(HotKey(keyCode: 126, carbonModifiers: M.option).spokenString() == "Option Up Arrow")
    }

    @Test("character keys use the layout's name when given, the US name otherwise")
    func layoutNames() {
        let key = HotKey(keyCode: 12 /* Q on US */, carbonModifiers: M.option)
        #expect(key.displayString() == "⌥Q")
        #expect(key.displayString(keyName: { _ in "a" }) == "⌥A")       // AZERTY
        #expect(key.displayString(keyName: { _ in " " }) == "⌥Q")       // blank falls back
        #expect(HotKey(keyCode: 999, carbonModifiers: M.command).displayString() == "⌘Key 999")
    }

    @Test("the default Ask shortcut is valid")
    func defaultIsValid() {
        #expect(HotKey.defaultAsk.problem == nil)
    }

    @Test("a shortcut needs Command, Option or Control unless it is a function key")
    func needsModifier() {
        #expect(HotKey(keyCode: 40, carbonModifiers: 0).problem == .needsModifier)
        #expect(HotKey(keyCode: 40, carbonModifiers: M.shift).problem == .needsModifier)
        #expect(HotKey(keyCode: 40, carbonModifiers: M.option).problem == nil)
        #expect(HotKey(keyCode: 97 /* F6 */, carbonModifiers: 0).problem == nil)
        #expect(HotKey(keyCode: 97, carbonModifiers: M.shift).problem == nil)
    }

    @Test("Esc, Return, Tab and Delete can't be the main key")
    func reservedKeys() {
        for code: UInt32 in [53, 36, 48, 51] {
            #expect(HotKey(keyCode: code, carbonModifiers: M.command | M.option).problem == .reservedKey)
        }
    }

    @Test("standard macOS shortcuts are refused")
    func systemShortcuts() {
        #expect(HotKey(keyCode: HotKey.Key.space, carbonModifiers: M.command).problem == .system("show Spotlight"))
        #expect(HotKey(keyCode: HotKey.Key.space, carbonModifiers: M.control | M.option).problem == .system("switch input sources"))
        #expect(HotKey(keyCode: 8 /* C */, carbonModifiers: M.command).problem == .system("copy"))
        #expect(HotKey(keyCode: 21 /* 4 */, carbonModifiers: M.shift | M.command).problem == .system("take screenshots"))
        #expect(HotKey(keyCode: 103 /* F11 */, carbonModifiers: 0).problem == .system("show the desktop"))
        // Same key, different modifiers: allowed.
        #expect(HotKey(keyCode: 8, carbonModifiers: M.option | M.command).problem == nil)
    }

    @Test("every problem has a message")
    func messages() {
        for problem in [HotKeyProblem.needsModifier, .reservedKey, .system("copy")] {
            #expect(!problem.message.isEmpty)
        }
        #expect(HotKeyProblem.system("copy").message.contains("copy"))
    }
}
