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
    /// network use), then streams the reply from the selected provider. An answer needs a
    /// transcript or a question; a summary needs a transcript. History is repaired and capped
    /// here (the one place it is trimmed), within what the transcript and question leave of
    /// `ChatHistory.maxCharacters`.
    public func streamReply(to request: ReplyRequest, settings: AssistantSettings) throws -> AsyncThrowingStream<ReplyEvent, Error> {
        let hasTranscript = !request.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasQuestion = !(request.question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        switch request.purpose {
        case .answer: guard hasTranscript || hasQuestion else { throw AssistantError.nothingToSend }
        case .summary: guard hasTranscript else { throw AssistantError.nothingToSend }
        }
        var request = request
        request.history = ChatHistory.trimmed(request.history, characterBudget: ChatHistory.characterBudget(for: request))

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
