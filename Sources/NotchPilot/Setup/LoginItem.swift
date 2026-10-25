import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// "Open NotchPilot at login" through `SMAppService.mainApp`. The state is never stored by
/// the app: it is read back from the service every time, so a change made in System
/// Settings › General › Login Items shows up here too. Off until the person turns it on
/// (HIG › The menu bar › Menu bar extras: "Let people — not your app — decide").
/// One instance, owned by the app delegate, backs both Settings › General and the setup
/// guide, so they always show the same status and error.
@MainActor
@Observable
final class LoginItemController {
    private(set) var status: SMAppService.Status = .notRegistered
    /// Why the last change didn't take, shown inline; nil when it worked.
    private(set) var errorMessage: String?

    init() {
        status = SMAppService.mainApp.status
    }

    /// On, including "on but waiting for approval in System Settings".
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    /// Assigns only on a change: the setup guide calls this every 2 seconds, and an
    /// unchanged assignment would still re-render observers.
    func refresh() {
        let current = SMAppService.mainApp.status
        if current != status { status = current }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = enabled
                ? "NotchPilot couldn’t add itself to your login items. You can add it in System Settings › General › Login Items."
                : "NotchPilot couldn’t remove itself from your login items. You can remove it in System Settings › General › Login Items."
        }
        refresh()
        // macOS can't find an app that runs from a disk image, Downloads or a translocated
        // copy; the fix is the usual one.
        if enabled, status == .notFound {
            errorMessage = "To open at login, NotchPilot needs to be in your Applications folder. Quit NotchPilot, drag it to the Applications folder, then open it from there and try again."
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The toggle plus its approval hint and error, shared by Settings › General (switch) and
/// the setup guide (checkbox).
struct LoginItemToggle: View {
    let loginItem: LoginItemController
    var asCheckbox = false

    var body: some View {
        let binding = Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })
        if asCheckbox {
            Toggle("Open NotchPilot at login", isOn: binding)
                .toggleStyle(.checkbox)
        } else {
            Toggle(isOn: binding) {
                Text("Open NotchPilot at login")
                Text("NotchPilot starts in the menu bar when you log in. Capture stays off until you start it.")
            }
        }
        if loginItem.requiresApproval {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Allow NotchPilot in System Settings › Login Items to finish.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Open Login Items") { loginItem.openLoginItemsSettings() }
            }
        }
        if let message = loginItem.errorMessage {
            ErrorLabel(message)
        }
    }
}

/// Settings › General's first section. Re-reads the status whenever NotchPilot becomes
/// active again, for example after approving it in System Settings.
struct LoginItemSection: View {
    let loginItem: LoginItemController

    var body: some View {
        Section {
            LoginItemToggle(loginItem: loginItem)
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}
