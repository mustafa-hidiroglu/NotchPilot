import NotchPilotCore
import SwiftUI

/// The panes of the Settings window (HIG › Settings › macOS: a toolbar of panes, window
/// title follows the pane, the most recently viewed pane is restored).
enum SettingsPane: String, CaseIterable {
    case general
    case assistant
    case speech

    static let width: CGFloat = 500

    var title: String {
        switch self {
        case .general: "General"
        case .assistant: "Assistant"
        case .speech: "Speech"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .assistant: "sparkles"
        case .speech: "waveform"
        }
    }
}

/// Settings › General: the Ask shortcut and the Include Screen default.
struct GeneralSettingsPane: View {
    @Bindable var store: AssistantSettingsStore
    let hotKeys: HotKeyCenter

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $store.settings.askHotKeyEnabled) {
                    Text("Ask from any app")
                    Text("Opens the island with the question field ready. Press Return to ask, or press the shortcut again or Esc to close.")
                }
                LabeledContent("Shortcut") {
                    ShortcutRecorder(hotKey: $store.settings.askHotKey,
                                     onRecordingChange: { hotKeys.setSuspended($0) })
                }
                .disabled(!store.settings.askHotKeyEnabled)
                if store.settings.askHotKeyEnabled, let error = hotKeys.registrationError {
                    ErrorLabel(error)
                }
                HStack {
                    Spacer()
                    Button("Restore Default") { store.settings.askHotKey = .defaultAsk }
                        .disabled(store.settings.askHotKey == .defaultAsk || !store.settings.askHotKeyEnabled)
                }
            } header: {
                Text("Keyboard Shortcut")
            }

            Section {
                Toggle(isOn: $store.settings.includeScreenshotByDefault) {
                    Text("Include screen by default")
                    Text("Ask attaches one screenshot of your main display. You can change this for each request in the island.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsPane.width, height: 330)
    }
}
