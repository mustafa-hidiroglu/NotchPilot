import Foundation

/// OpenAI Chat Completions client.
public struct OpenAIClient: ReplyGenerating {
    public static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let maxCompletionTokens = 4_096

    public let provider = AIProvider.openAI
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? ProviderHTTP.defaultSession
    }

    public func reply(to request: ReplyRequest, apiKey: String, settings: AssistantSettings) async throws -> AssistantReply {
        let urlRequest = try ProviderHTTP.jsonRequest(
            url: Self.endpoint,
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: Self.body(for: request, settings: settings)
        )
        let data = try await ProviderHTTP.send(urlRequest, session: session, provider: provider)
        guard let response = try? JSONDecoder().decode(CompletionResponse.self, from: data),
              let choice = response.choices.first
        else { throw AssistantError.invalidResponse(provider) }
        if choice.message.refusal != nil { throw AssistantError.refused(provider) }
        guard let text = choice.message.content else { throw AssistantError.invalidResponse(provider) }
        return AssistantReply(text: text, provider: provider, model: response.model, truncated: choice.finishReason == "length")
    }

    static func body(for request: ReplyRequest, settings: AssistantSettings) -> CompletionRequest {
        var parts: [UserPart] = [.text(ProviderHTTP.composedText(for: request))]
        if let jpeg = request.screenshotJPEG {
            parts.append(.imageURL("data:image/jpeg;base64,\(jpeg.base64EncodedString())"))
        }
        return CompletionRequest(
            model: settings.openAIModel,
            maxCompletionTokens: maxCompletionTokens,
            messages: [.system(request.systemPrompt), .user(parts)]
        )
    }

    // MARK: - Wire format

    struct CompletionRequest: Encodable {
        var model: String
        var maxCompletionTokens: Int
        var messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model, messages
            case maxCompletionTokens = "max_completion_tokens"
        }
    }

    enum Message: Encodable {
        case system(String)
        case user([UserPart])

        private enum CodingKeys: String, CodingKey { case role, content }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .system(let text):
                try container.encode("system", forKey: .role)
                try container.encode(text, forKey: .content)
            case .user(let parts):
                try container.encode("user", forKey: .role)
                try container.encode(parts, forKey: .content)
            }
        }
    }

    enum UserPart: Encodable {
        case text(String)
        case imageURL(String)

        private struct ImageURL: Encodable { var url: String }
        private enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .imageURL(let url):
                try container.encode("image_url", forKey: .type)
                try container.encode(ImageURL(url: url), forKey: .imageURL)
            }
        }
    }

    struct CompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
                var refusal: String?
            }
            var message: Message
            var finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        var model: String
        var choices: [Choice]
    }
}
