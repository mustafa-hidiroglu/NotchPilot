import AppKit

// Menu-bar utility: no Dock icon, no app-switcher entry. `LSUIElement` in Info.plist does the
// same for the bundled app; setting the policy here also covers `swift run`.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        application.run()
    }
}
