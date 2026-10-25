import Testing
@testable import NotchPilotCore

@Suite("First-run setup checklist")
struct SetupChecklistTests {
    private func snapshot(permission: Bool = false, requested: Bool = false,
                          model: SpeechModelInstallState = .notInstalled, key: Bool = false) -> SetupSnapshot {
        SetupSnapshot(hasScreenCapturePermission: permission, didRequestScreenCapture: requested,
                      speechModelState: model, hasAPIKey: key)
    }

    @Test("a fresh install has every step to do, starting with screen recording")
    func freshInstall() {
        let fresh = snapshot()
        for step in SetupStep.allCases {
            #expect(SetupChecklist.status(of: step, in: fresh) == .toDo)
        }
        #expect(SetupChecklist.completedCount(in: fresh) == 0)
        #expect(SetupChecklist.nextStep(in: fresh) == .screenRecording)
        #expect(!SetupChecklist.isComplete(fresh))
    }

    @Test("screen recording offers the system prompt once, then System Settings")
    func screenRecordingAction() {
        #expect(SetupChecklist.screenRecordingAction(in: snapshot()) == .requestAccess)
        #expect(SetupChecklist.screenRecordingAction(in: snapshot(requested: true)) == .openPrivacySettings)
        #expect(SetupChecklist.screenRecordingAction(in: snapshot(permission: true, requested: true)) == .none)
        #expect(SetupChecklist.screenRecordingAction(in: snapshot(permission: true)) == .none)
    }

    @Test("a declined prompt needs attention; a grant is done whether or not the guide asked")
    func screenRecordingStatus() {
        guard case .needsAttention(let message) = SetupChecklist.status(of: .screenRecording, in: snapshot(requested: true)) else {
            Issue.record("expected needsAttention")
            return
        }
        #expect(message.contains("Screen & System Audio Recording"))
        #expect(SetupChecklist.status(of: .screenRecording, in: snapshot(permission: true)) == .done)
    }

    @Test("the speech step follows the model's install state, with progress clamped")
    func speechModel() {
        #expect(SetupChecklist.status(of: .speechModel, in: snapshot(model: .downloading(fraction: 0.4))) == .inProgress(fraction: 0.4))
        #expect(SetupChecklist.status(of: .speechModel, in: snapshot(model: .downloading(fraction: 1.7))) == .inProgress(fraction: 1))
        #expect(SetupChecklist.status(of: .speechModel, in: snapshot(model: .downloading(fraction: -1))) == .inProgress(fraction: 0))
        #expect(SetupChecklist.status(of: .speechModel, in: snapshot(model: .failed("Checksum mismatch"))) == .needsAttention("Checksum mismatch"))
        #expect(SetupChecklist.status(of: .speechModel, in: snapshot(model: .installed)) == .done)
    }

    @Test("next step skips finished ones; all three done completes setup")
    func progression() {
        let partial = snapshot(permission: true, key: true)
        #expect(SetupChecklist.completedCount(in: partial) == 2)
        #expect(SetupChecklist.nextStep(in: partial) == .speechModel)

        let finished = snapshot(permission: true, model: .installed, key: true)
        #expect(SetupChecklist.isComplete(finished))
        #expect(SetupChecklist.nextStep(in: finished) == nil)
    }

    @Test("the shortcut tip follows the single- and double-press settings")
    func shortcutTip() {
        #expect(SetupChecklist.shortcutTip(shortcut: "⇧⌘Space", singlePress: .once, doublePress: true)
                == "Press ⇧⌘Space from any app once to ask one question, or twice quickly to start a chat with follow-up questions.")
        #expect(SetupChecklist.shortcutTip(shortcut: "⇧⌘Space", singlePress: .chat, doublePress: true)
                == "Press ⇧⌘Space from any app once to start a chat with follow-up questions, or twice quickly to ask one question.")
        #expect(SetupChecklist.shortcutTip(shortcut: "⌥K", singlePress: .once, doublePress: false)
                == "Press ⌥K from any app to ask one question.")
        #expect(SetupChecklist.shortcutTip(shortcut: "⌥K", singlePress: .chat, doublePress: false)
                == "Press ⌥K from any app to start a chat with follow-up questions.")
        #expect(SetupChecklist.shortcutTip(shortcut: nil, singlePress: .once, doublePress: true).contains("Settings › General"))
    }
}
