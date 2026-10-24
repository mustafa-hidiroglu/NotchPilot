import Foundation

/// Validates an Ask and sends it to the provider selected in settings.
public struct ReplyService: Sendable {
    private let keyStore: any APIKeyStoring
    private let claude: any ReplyGenerating
    private let openAI: any ReplyGenerating

    public init(
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        claude: any ReplyGenerating = ClaudeClient(),
        openAI: any ReplyGenerating = OpenAIClient()
    ) {
        self.keyStore = keyStore
        self.claude = claude
        self.openAI = openAI
    }

    public func reply(to request: ReplyRequest, settings: AssistantSettings) async throws -> AssistantReply {
        try await AssistantReply.collect(streamReply(to: request, settings: settings), provider: settings.provider)
    }

    /// Validates the Ask synchronously (throws `.nothingToSend` or `.missingAPIKey` before any
    /// network use), then streams the reply from the selected provider.
    public func streamReply(to request: ReplyRequest, settings: AssistantSettings) throws -> AsyncThrowingStream<ReplyEvent, Error> {
        let hasTranscript = !request.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasQuestion = !(request.question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard hasTranscript || hasQuestion else { throw AssistantError.nothingToSend }

        let provider = settings.provider
        guard let apiKey = try keyStore.apiKey(for: provider)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else { throw AssistantError.missingAPIKey(provider) }
        let client = switch provider {
        case .claude: claude
        case .openAI: openAI
        }
        return client.streamReply(to: request, apiKey: apiKey, settings: settings)
    }
}
