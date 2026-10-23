import Foundation

/// Claude Messages API client (raw HTTPS; there is no Swift SDK).
public struct ClaudeClient: ReplyGenerating {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let maxTokens = 16_000

    public let provider = AIProvider.claude
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? ProviderHTTP.defaultSession
    }

    public func reply(to request: ReplyRequest, apiKey: String, settings: AssistantSettings) async throws -> AssistantReply {
        let urlRequest = try ProviderHTTP.jsonRequest(
            url: Self.endpoint,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                "anthropic-beta": "server-side-fallback-2026-07-01",
            ],
            body: Self.body(for: request, settings: settings)
        )
        let data = try await ProviderHTTP.send(urlRequest, session: session, provider: provider)
        guard let response = try? JSONDecoder().decode(MessageResponse.self, from: data) else {
            throw AssistantError.invalidResponse(provider)
        }
        if response.stopReason == "refusal" { throw AssistantError.refused(provider) }
        let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        let truncated = response.stopReason == "max_tokens"
        guard !text.isEmpty || truncated else { throw AssistantError.invalidResponse(provider) }
        return AssistantReply(text: text, provider: provider, model: response.model, truncated: truncated)
    }

    static func body(for request: ReplyRequest, settings: AssistantSettings) -> MessageRequest {
        var content: [ContentBlock] = []
        if let jpeg = request.screenshotJPEG {
            content.append(.image(base64JPEG: jpeg.base64EncodedString()))
        }
        content.append(.text(ProviderHTTP.composedText(for: request)))
        return MessageRequest(
            model: settings.claudeModel,
            maxTokens: maxTokens,
            system: request.systemPrompt,
            messages: [.init(role: "user", content: content)],
            outputConfig: .init(effort: settings.claudeEffort),
            fallbacks: "default"
        )
    }

    // MARK: - Wire format

    // `thinking`, `temperature` and `top_p` are deliberately absent: this model rejects them.
    struct MessageRequest: Encodable {
        struct Message: Encodable {
            var role: String
            var content: [ContentBlock]
        }
        struct OutputConfig: Encodable { var effort: String }

        var model: String
        var maxTokens: Int
        var system: String
        var messages: [Message]
        var outputConfig: OutputConfig
        var fallbacks: String

        enum CodingKeys: String, CodingKey {
            case model, system, messages, fallbacks
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }
    }

    enum ContentBlock: Encodable {
        case image(base64JPEG: String)
        case text(String)

        private struct ImageSource: Encodable {
            var type = "base64"
            var mediaType = "image/jpeg"
            var data: String
            enum CodingKeys: String, CodingKey {
                case type, data
                case mediaType = "media_type"
            }
        }
        private enum CodingKeys: String, CodingKey { case type, source, text }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .image(let data):
                try container.encode("image", forKey: .type)
                try container.encode(ImageSource(data: data), forKey: .source)
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            }
        }
    }

    struct MessageResponse: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        var model: String
        var content: [Block]
        var stopReason: String?

        enum CodingKeys: String, CodingKey {
            case model, content
            case stopReason = "stop_reason"
        }
    }
}
