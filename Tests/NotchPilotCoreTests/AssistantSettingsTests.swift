import Foundation
import Testing
@testable import NotchPilotCore

@Suite("AssistantSettings decoding")
struct AssistantSettingsTests {
    private func decode(_ json: String) throws -> AssistantSettings {
        try JSONDecoder().decode(AssistantSettings.self, from: Data(json.utf8))
    }

    @Test("an empty object decodes to the defaults")
    func empty() throws {
        #expect(try decode("{}") == AssistantSettings())
    }

    @Test("missing keys keep their defaults, present keys are kept")
    func partial() throws {
        let settings = try decode(#"{"provider":"openAI","openAIModel":"my-model"}"#)
        #expect(settings.provider == .openAI)
        #expect(settings.openAIModel == "my-model")
        #expect(settings.claudeModel == AssistantSettings().claudeModel)
    }

    @Test("an unknown provider or a wrongly typed field doesn't reset the rest")
    func tolerant() throws {
        let settings = try decode(#"{"provider":"gemini","claudeModel":"x","transcriptCharacterLimit":"lots"}"#)
        #expect(settings.provider == .claude)
        #expect(settings.claudeModel == "x")
        #expect(settings.transcriptCharacterLimit == AssistantSettings().transcriptCharacterLimit)
    }

    @Test("round-trips through JSON")
    func roundTrip() throws {
        var settings = AssistantSettings()
        settings.provider = .openAI
        settings.includeScreenshotByDefault = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AssistantSettings.self, from: data) == settings)
    }

    @Test("a non-positive transcript limit yields no text instead of trapping")
    func badLimit() {
        let transcript = Transcript(finalText: "hello world")
        #expect(transcript.recentText(limit: 0).isEmpty)
        #expect(transcript.recentText(limit: -5).isEmpty)
    }
}
