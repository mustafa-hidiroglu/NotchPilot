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

    public func streamReply(to request: ReplyRequest, apiKey: String, settings: AssistantSettings) -> AsyncThrowingStream<ReplyEvent, Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try ProviderHTTP.jsonRequest(
                url: Self.endpoint,
                headers: [
                    "x-api-key": apiKey,
                    "anthropic-version": "2023-06-01",
                    "anthropic-beta": "server-side-fallback-2026-07-01",
                ],
                body: Self.body(for: request, settings: settings)
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: AssistantError.invalidResponse(provider)) }
        }
        return ProviderHTTP.replyStream(urlRequest, session: session, provider: provider, decoder: StreamDecoder())
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
        var stream = true

        enum CodingKeys: String, CodingKey {
            case model, system, messages, fallbacks, stream
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

    /// Messages streaming events. Only text blocks reach the reply: `thinking` blocks and the
    /// `fallback` audit marker (written when a server-side fallback switches models
    /// mid-response) are skipped. A fallback before any output just means `message_start`
    /// names the fallback model.
    struct StreamDecoder: ReplyStreamDecoding {
        private var textBlocks: Set<Int> = []
        private var stopReason: String?

        mutating func decode(_ event: ServerSentEvent) throws -> [ReplyEvent] {
            guard let payload = try? JSONDecoder().decode(StreamEvent.self, from: Data(event.data.utf8)) else {
                throw AssistantError.invalidResponse(.claude)
            }
            switch payload.type {
            case "message_start":
                guard let model = payload.message?.model else { throw AssistantError.invalidResponse(.claude) }
                return [.started(model: model)]
            case "content_block_start":
                if payload.contentBlock?.type == "text", let index = payload.index { textBlocks.insert(index) }
            case "content_block_delta":
                if let index = payload.index, textBlocks.contains(index),
                   payload.delta?.type == "text_delta", let text = payload.delta?.text {
                    return [.textDelta(text)]
                }
            case "message_delta":
                if let reason = payload.delta?.stopReason {
                    if reason == "refusal" { throw AssistantError.refused(.claude) }
                    stopReason = reason
                }
            case "message_stop":
                return [.finished(truncated: stopReason == "max_tokens")]
            case "error":
                throw Self.error(type: payload.error?.type, message: payload.error?.message)
            default:
                break // ping, content_block_stop, and event types added later
            }
            return []
        }

        /// Maps an `error` event through the HTTP status the same error type has.
        static func error(type: String?, message: String?) -> AssistantError {
            let status = switch type {
            case "invalid_request_error": 400
            case "authentication_error": 401
            case "permission_error": 403
            case "not_found_error": 404
            case "request_too_large": 413
            case "rate_limit_error": 429
            case "timeout_error": 504
            case "overloaded_error": 529
            default: 500 // api_error and unknown types
            }
            return ProviderHTTP.error(status: status, message: message, provider: .claude)
                ?? .providerUnavailable(.claude, status: status)
        }
    }

    struct StreamEvent: Decodable {
        struct Message: Decodable { var model: String }
        struct Block: Decodable { var type: String }
        struct Delta: Decodable {
            var type: String?
            var text: String?
            var stopReason: String?
            enum CodingKeys: String, CodingKey {
                case type, text
                case stopReason = "stop_reason"
            }
        }
        struct ErrorDetail: Decodable {
            var type: String?
            var message: String?
        }
        var type: String
        var index: Int?
        var message: Message?
        var contentBlock: Block?
        var delta: Delta?
        var error: ErrorDetail?

        enum CodingKeys: String, CodingKey {
            case type, index, message, delta, error
            case contentBlock = "content_block"
        }
    }
}
