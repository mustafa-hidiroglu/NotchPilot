import Foundation

// Pure logic behind the first-run setup guide: which steps are done, what each step offers
// next, and how the shortcut tip is phrased. The app target gathers the live facts
// (permission, model install state, Keychain) into a `SetupSnapshot`; nothing here touches
// the system, so it can be unit tested.

public enum SetupStep: String, CaseIterable, Sendable, Identifiable {
    case screenRecording
    case speechModel
    case apiKey

    public var id: String { rawValue }
}

/// Live facts the guide is built from. Refreshed when the guide window becomes key and on a
/// light timer while it is open.
public struct SetupSnapshot: Sendable, Equatable {
    /// `CGPreflightScreenCaptureAccess()`.
    public var hasScreenCapturePermission: Bool
    /// The guide already showed the one-time system prompt (`CGRequestScreenCaptureAccess`
    /// prompts only once; afterwards only System Settings can grant access).
    public var didRequestScreenCapture: Bool
    /// Install state of the selected speech model.
    public var speechModelState: SpeechModelInstallState
    /// A key is stored in the Keychain for the selected provider.
    public var hasAPIKey: Bool

    public init(hasScreenCapturePermission: Bool, didRequestScreenCapture: Bool,
                speechModelState: SpeechModelInstallState, hasAPIKey: Bool) {
        self.hasScreenCapturePermission = hasScreenCapturePermission
        self.didRequestScreenCapture = didRequestScreenCapture
        self.speechModelState = speechModelState
        self.hasAPIKey = hasAPIKey
    }
}

public enum SetupStepStatus: Sendable, Equatable {
    case toDo
    /// Determinate progress, 0...1 (the model download).
    case inProgress(fraction: Double)
    /// Something went wrong or needs the person's attention elsewhere; the message says what.
    case needsAttention(String)
    case done

    public var isDone: Bool { self == .done }
}

/// What the Screen & System Audio Recording step offers.
public enum ScreenRecordingAction: Sendable, Equatable {
    /// Show the system prompt (first time only).
    case requestAccess
    /// The prompt was already shown: only System Settings can grant access now.
    case openPrivacySettings
    case none
}

public enum SetupChecklist {
    public static func status(of step: SetupStep, in snapshot: SetupSnapshot) -> SetupStepStatus {
        switch step {
        case .screenRecording:
            if snapshot.hasScreenCapturePermission { return .done }
            return snapshot.didRequestScreenCapture
                ? .needsAttention("Turn on NotchPilot in Privacy & Security › Screen & System Audio Recording.")
                : .toDo
        case .speechModel:
            switch snapshot.speechModelState {
            case .installed: return .done
            case .notInstalled: return .toDo
            case .downloading(let fraction): return .inProgress(fraction: min(max(fraction, 0), 1))
            case .failed(let message): return .needsAttention(message)
            }
        case .apiKey:
            return snapshot.hasAPIKey ? .done : .toDo
        }
    }

    public static func screenRecordingAction(in snapshot: SetupSnapshot) -> ScreenRecordingAction {
        if snapshot.hasScreenCapturePermission { return .none }
        return snapshot.didRequestScreenCapture ? .openPrivacySettings : .requestAccess
    }

    public static func completedCount(in snapshot: SetupSnapshot) -> Int {
        SetupStep.allCases.filter { status(of: $0, in: snapshot).isDone }.count
    }

    public static func isComplete(_ snapshot: SetupSnapshot) -> Bool {
        completedCount(in: snapshot) == SetupStep.allCases.count
    }

    /// The first step that isn't done, in guide order; nil when everything is.
    public static func nextStep(in snapshot: SetupSnapshot) -> SetupStep? {
        SetupStep.allCases.first { !status(of: $0, in: snapshot).isDone }
    }

    /// The closing tip about the Ask shortcut. `shortcut` is the display form (for example
    /// "⇧⌘Space"), or nil when the shortcut is off or couldn't be registered.
    public static func shortcutTip(shortcut: String?, singlePress: AskMode, doublePress: Bool) -> String {
        guard let shortcut else {
            return "Choose Ask from the NotchPilot icon in the menu bar. You can turn on a keyboard shortcut in Settings › General."
        }
        let single = phrase(for: singlePress)
        guard doublePress else { return "Press \(shortcut) from any app to \(single)." }
        return "Press \(shortcut) from any app once to \(single), or twice quickly to \(phrase(for: singlePress.other))."
    }

    private static func phrase(for mode: AskMode) -> String {
        switch mode {
        case .once: "ask one question"
        case .chat: "start a chat with follow-up questions"
        }
    }
}
