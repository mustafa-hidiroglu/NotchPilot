import Foundation

/// OpenAI Chat Completions client.
public struct OpenAIClient: ReplyGenerating {
    public static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    /// Includes reasoning tokens on reasoning models, so it must leave room for the answer.
    static let maxCompletionTokens = 16_000

    public let provider = AIProvider.openAI
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? ProviderHTTP.defaultSession
    }

    public func streamReply(to request: ReplyRequest, apiKey: String, settings: AssistantSettings) -> AsyncThrowingStream<ReplyEvent, Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try ProviderHTTP.jsonRequest(
                url: Self.endpoint,
                headers: ["Authorization": "Bearer \(apiKey)"],
                body: Self.body(for: request, settings: settings)
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: AssistantError.invalidResponse(provider)) }
        }
        return ProviderHTTP.replyStream(urlRequest, session: session, provider: provider, decoder: StreamDecoder())
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
        var stream = true

        enum CodingKeys: String, CodingKey {
            case model, messages, stream
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

    /// Chat Completions streaming chunks: one JSON object per `data:` line, ended by
    /// `data: [DONE]`.
    struct StreamDecoder: ReplyStreamDecoding {
        private var started = false
        private var text = ""
        private var finishReason: String?

        mutating func decode(_ event: ServerSentEvent) throws -> [ReplyEvent] {
            if event.data == "[DONE]" {
                let truncated = finishReason == "length"
                // Blank content on a complete reply is not usable. A blank truncated one (the whole
                // budget went to reasoning) finishes like Claude's: the person sees it was cut off.
                guard truncated || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AssistantError.invalidResponse(.openAI)
                }
                return [.finished(truncated: truncated)]
            }
            guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(event.data.utf8)) else {
                throw AssistantError.invalidResponse(.openAI)
            }
            if let error = chunk.error { throw Self.error(error) }

            var events: [ReplyEvent] = []
            if !started {
                started = true
                events.append(.started(model: chunk.model ?? ""))
            }
            guard let choice = chunk.choices?.first else { return events }
            if let refusal = choice.delta?.refusal, !refusal.isEmpty { throw AssistantError.refused(.openAI) }
            if let content = choice.delta?.content, !content.isEmpty {
                text += content
                events.append(.textDelta(content))
            }
            if let reason = choice.finishReason {
                if reason == "content_filter" { throw AssistantError.refused(.openAI) }
                finishReason = reason
            }
            return events
        }

        /// Maps an error object that arrived mid-stream through its HTTP status equivalent.
        static func error(_ error: Chunk.ErrorDetail) -> AssistantError {
            let kind = error.code ?? error.type ?? ""
            let status = switch kind {
            case "invalid_api_key", "authentication_error": 401
            case "rate_limit_exceeded", "insufficient_quota": 429
            case "invalid_request_error", "model_not_found", "context_length_exceeded": 400
            default: 500 // server_error and unknown kinds
            }
            return ProviderHTTP.error(status: status, message: error.message, provider: .openAI)
                ?? .providerUnavailable(.openAI, status: status)
        }
    }

    struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                var content: String?
                var refusal: String?
            }
            var delta: Delta?
            var finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }
        struct ErrorDetail: Decodable {
            var message: String?
            var type: String?
            var code: String?
        }
        var model: String?
        var choices: [Choice]?
        var error: ErrorDetail?
    }
}
