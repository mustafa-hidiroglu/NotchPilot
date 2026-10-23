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
        return try await client.reply(to: request, apiKey: apiKey, settings: settings)
    }
}
