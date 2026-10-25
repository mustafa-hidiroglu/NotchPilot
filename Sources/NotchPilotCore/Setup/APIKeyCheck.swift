import Foundation

/// "Check Key" in the setup guide: one minimal request, only when the person presses the
/// button, through the same `ReplyService` path as Ask. It carries no transcript, no
/// screenshot and no chat history: just a fixed system prompt and a one-word question.
///
/// The check succeeds as soon as the provider starts replying (HTTP 2xx and the first
/// stream event, so both the key and the model were accepted). Returning stops reading and
/// ends the stream, which cancels the request, so only a few tokens are generated.
/// Provider errors come back as the usual `AssistantError` (for example `.invalidAPIKey`).
public enum APIKeyCheck {
    public static let systemPrompt = "This is a connection check from NotchPilot. Reply with the single word OK."
    public static let question = "OK?"

    public static var request: ReplyRequest {
        ReplyRequest(transcript: "", question: question, systemPrompt: systemPrompt)
    }

    public static func run(with service: ReplyService, settings: AssistantSettings) async throws {
        var settings = settings
        settings.claudeEffort = "low"   // the least work the provider can do for it
        let stream = try service.streamReply(to: request, settings: settings)
        for try await _ in stream { return }
        throw AssistantError.invalidResponse(settings.provider)
    }
}
