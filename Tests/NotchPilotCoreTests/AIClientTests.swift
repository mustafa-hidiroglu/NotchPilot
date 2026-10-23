import Foundation
import Testing
@testable import NotchPilotCore

// MARK: - URLProtocol stub

private struct StubResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data
}

/// Intercepts every request made through `stubSession()`. The handler and captured request
/// are static, so the suite below is serialised.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _response: StubResponse?
    nonisolated(unsafe) private static var _failure: URLError?
    nonisolated(unsafe) private static var _captured: (request: URLRequest, body: Data)?

    static func respond(_ response: StubResponse) {
        lock.withLock { _response = response; _failure = nil; _captured = nil }
    }

    static func fail(_ error: URLError) {
        lock.withLock { _response = nil; _failure = error; _captured = nil }
    }

    static var captured: (request: URLRequest, body: Data)? { lock.withLock { _captured } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = request.httpBody ?? Self.readStream(request.httpBodyStream)
        let (response, failure) = Self.lock.withLock {
            Self._captured = (request, body)
            return (Self._response, Self._failure)
        }
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let response, let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func capturedJSON() throws -> [String: Any] {
    let body = try #require(StubURLProtocol.captured?.body)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private struct InMemoryKeyStore: APIKeyStoring {
    var keys: [AIProvider: String] = [:]
    func apiKey(for provider: AIProvider) throws -> String? { keys[provider] }
    func setAPIKey(_ key: String, for provider: AIProvider) throws {}
    func removeAPIKey(for provider: AIProvider) throws {}
}

private struct RecordingClient: ReplyGenerating {
    let provider: AIProvider
    func reply(to request: ReplyRequest, apiKey: String, settings: AssistantSettings) async throws -> AssistantReply {
        AssistantReply(text: "key=\(apiKey)", provider: provider, model: "stub")
    }
}

private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
private let claudeOK = json([
    "model": "claude-opus-5-5",
    "stop_reason": "end_turn",
    "content": [
        ["type": "thinking", "thinking": "hidden"],
        ["type": "text", "text": "Hello"],
        ["type": "fallback", "text": "ignored"],
        ["type": "text", "text": " world"],
    ],
])

// MARK: - Tests

@Suite("AI clients", .serialized)
struct AIClientTests {

    // MARK: Claude

    @Test("Claude request has the documented URL, headers and body")
    func claudeRequestShape() async throws {
        StubURLProtocol.respond(.init(status: 200, body: claudeOK))
        var settings = AssistantSettings()
        settings.claudeEffort = "medium"
        let request = ReplyRequest(transcript: "we ship friday", question: "What day?", screenshotJPEG: jpeg, systemPrompt: "SYS")
        _ = try await ClaudeClient(session: stubSession()).reply(to: request, apiKey: "sk-test", settings: settings)

        let sent = try #require(StubURLProtocol.captured?.request)
        #expect(sent.url == URL(string: "https://api.anthropic.com/v1/messages"))
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(sent.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(sent.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(sent.timeoutInterval == ProviderHTTP.timeout)

        let body = try capturedJSON()
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["max_tokens"] as? Int == 16_000)
        #expect(body["system"] as? String == "SYS")
        #expect(body["fallbacks"] as? String == "default")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(body["thinking"] == nil)
        #expect(body["temperature"] == nil)
        #expect(body["top_p"] == nil)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == jpeg.base64EncodedString())
        #expect(content[1]["text"] as? String
            == "Transcript of audio playing on my Mac (most recent last):\nwe ship friday\n\nMy question: What day?")
    }

    @Test("Claude without screenshot or question sends one text block asking for a helpful response")
    func claudeTextOnly() async throws {
        StubURLProtocol.respond(.init(status: 200, body: claudeOK))
        let request = ReplyRequest(transcript: "hello", systemPrompt: "SYS")
        _ = try await ClaudeClient(session: stubSession()).reply(to: request, apiKey: "k", settings: AssistantSettings())

        let messages = try #require(try capturedJSON()["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["text"] as? String
            == "Transcript of audio playing on my Mac (most recent last):\nhello\n\nRespond helpfully to what's being said.")
    }

    @Test("Claude joins text blocks only and reports the response model")
    func claudeParsesText() async throws {
        StubURLProtocol.respond(.init(status: 200, body: claudeOK))
        let reply = try await ClaudeClient(session: stubSession())
            .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        #expect(reply == AssistantReply(text: "Hello world", provider: .claude, model: "claude-opus-5-5", truncated: false))
    }

    @Test("Claude stop_reason refusal throws refused")
    func claudeRefusal() async throws {
        StubURLProtocol.respond(.init(status: 200, body: json([
            "model": "claude-opus-5-5", "stop_reason": "refusal", "content": [["type": "text", "text": "partial"]],
        ])))
        await #expect(throws: AssistantError.refused(.claude)) {
            try await ClaudeClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        }
    }

    @Test("Claude stop_reason max_tokens marks the reply truncated")
    func claudeTruncated() async throws {
        StubURLProtocol.respond(.init(status: 200, body: json([
            "model": "claude-opus-5-5", "stop_reason": "max_tokens", "content": [["type": "text", "text": "cut"]],
        ])))
        let reply = try await ClaudeClient(session: stubSession())
            .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        #expect(reply.truncated)
        #expect(reply.text == "cut")
    }

    @Test("Claude HTTP errors map to AssistantError", arguments: [
        (StubResponse(status: 401, body: Data()), AssistantError.invalidAPIKey(.claude)),
        (StubResponse(status: 403, body: Data()), AssistantError.invalidAPIKey(.claude)),
        (StubResponse(status: 429, headers: ["retry-after": "17"], body: Data()), AssistantError.rateLimited(.claude, retryAfterSeconds: 17)),
        (StubResponse(status: 429, body: Data()), AssistantError.rateLimited(.claude, retryAfterSeconds: nil)),
        (StubResponse(status: 529, body: Data()), AssistantError.providerUnavailable(.claude, status: 529)),
        (StubResponse(status: 503, body: Data()), AssistantError.providerUnavailable(.claude, status: 503)),
        (StubResponse(status: 400, body: json([
            "type": "error", "error": ["type": "invalid_request_error", "message": "model: not found"],
        ])), AssistantError.requestRejected(.claude, status: 400, message: "model: not found")),
    ])
    fileprivate func claudeHTTPErrors(stub: StubResponse, expected: AssistantError) async throws {
        StubURLProtocol.respond(stub)
        await #expect(throws: expected) {
            try await ClaudeClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        }
    }

    @Test("Undecodable 200 body throws invalidResponse")
    func claudeUndecodable() async throws {
        StubURLProtocol.respond(.init(status: 200, body: Data("not json".utf8)))
        await #expect(throws: AssistantError.invalidResponse(.claude)) {
            try await ClaudeClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        }
    }

    @Test("URLError maps to network")
    func networkError() async throws {
        StubURLProtocol.fail(URLError(.notConnectedToInternet))
        do {
            _ = try await ClaudeClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
            Issue.record("expected a network error")
        } catch let AssistantError.network(detail) {
            #expect(!detail.isEmpty)
        }
    }

    // MARK: OpenAI

    @Test("OpenAI request has the documented URL, headers and body")
    func openAIRequestShape() async throws {
        StubURLProtocol.respond(.init(status: 200, body: json([
            "model": "gpt-5-2026", "choices": [["message": ["content": "Hi", "refusal": NSNull()], "finish_reason": "stop"]],
        ])))
        var settings = AssistantSettings()
        settings.openAIModel = "gpt-5-mini"
        let request = ReplyRequest(transcript: "tx", screenshotJPEG: jpeg, systemPrompt: "SYS")
        let reply = try await OpenAIClient(session: stubSession()).reply(to: request, apiKey: "sk-oa", settings: settings)
        #expect(reply == AssistantReply(text: "Hi", provider: .openAI, model: "gpt-5-2026", truncated: false))

        let sent = try #require(StubURLProtocol.captured?.request)
        #expect(sent.url == URL(string: "https://api.openai.com/v1/chat/completions"))
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-oa")
        #expect(sent.value(forHTTPHeaderField: "content-type") == "application/json")

        let body = try capturedJSON()
        #expect(body["model"] as? String == "gpt-5-mini")
        #expect(body["max_completion_tokens"] as? Int == OpenAIClient.maxCompletionTokens)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages[0]["content"] as? String == "SYS")
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["text", "image_url"])
        #expect(parts[0]["text"] as? String
            == "Transcript of audio playing on my Mac (most recent last):\ntx\n\nRespond helpfully to what's being said.")
        #expect((parts[1]["image_url"] as? [String: Any])?["url"] as? String
            == "data:image/jpeg;base64,\(jpeg.base64EncodedString())")
    }

    @Test("OpenAI refusal throws refused")
    func openAIRefusal() async throws {
        StubURLProtocol.respond(.init(status: 200, body: json([
            "model": "gpt-5", "choices": [["message": ["content": NSNull(), "refusal": "No."], "finish_reason": "stop"]],
        ])))
        await #expect(throws: AssistantError.refused(.openAI)) {
            try await OpenAIClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        }
    }

    @Test("OpenAI empty content (budget spent on reasoning) is not returned as a blank reply")
    func openAIEmptyContent() async throws {
        StubURLProtocol.respond(.init(status: 200, body: json([
            "model": "gpt-5", "choices": [["message": ["content": "", "refusal": NSNull()], "finish_reason": "length"]],
        ])))
        await #expect(throws: AssistantError.invalidResponse(.openAI)) {
            try await OpenAIClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        }
    }

    @Test("OpenAI finish_reason length marks the reply truncated")
    func openAITruncated() async throws {
        StubURLProtocol.respond(.init(status: 200, body: json([
            "model": "gpt-5", "choices": [["message": ["content": "cut"], "finish_reason": "length"]],
        ])))
        let reply = try await OpenAIClient(session: stubSession())
            .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        #expect(reply.truncated)
    }

    @Test("OpenAI error JSON message becomes requestRejected; 401 becomes invalidAPIKey")
    func openAIErrors() async throws {
        StubURLProtocol.respond(.init(status: 404, body: json(["error": ["message": "model does not exist"]])))
        await #expect(throws: AssistantError.requestRejected(.openAI, status: 404, message: "model does not exist")) {
            try await OpenAIClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        }
        StubURLProtocol.respond(.init(status: 401, body: Data()))
        await #expect(throws: AssistantError.invalidAPIKey(.openAI)) {
            try await OpenAIClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        }
    }

    // MARK: ReplyService

    private func service(keys: [AIProvider: String]) -> ReplyService {
        ReplyService(
            keyStore: InMemoryKeyStore(keys: keys),
            claude: RecordingClient(provider: .claude),
            openAI: RecordingClient(provider: .openAI)
        )
    }

    @Test("Empty transcript and no question throws nothingToSend")
    func nothingToSend() async throws {
        await #expect(throws: AssistantError.nothingToSend) {
            try await service(keys: [.claude: "k"])
                .reply(to: ReplyRequest(transcript: "  \n", question: " ", systemPrompt: "s"), settings: AssistantSettings())
        }
    }

    @Test("Missing or blank key throws missingAPIKey for the selected provider")
    func missingKey() async throws {
        var settings = AssistantSettings()
        settings.provider = .openAI
        await #expect(throws: AssistantError.missingAPIKey(.openAI)) {
            try await service(keys: [.claude: "k"]).reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), settings: settings)
        }
        await #expect(throws: AssistantError.missingAPIKey(.openAI)) {
            try await service(keys: [.openAI: "  "]).reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), settings: settings)
        }
    }

    @Test("Dispatches to the selected provider with the trimmed key; a question alone is enough")
    func dispatches() async throws {
        let keys: [AIProvider: String] = [.claude: " c-key\n", .openAI: "o-key"]
        var settings = AssistantSettings()
        let claudeReply = try await service(keys: keys)
            .reply(to: ReplyRequest(transcript: "", question: "Why?", systemPrompt: "s"), settings: settings)
        #expect(claudeReply == AssistantReply(text: "key=c-key", provider: .claude, model: "stub"))

        settings.provider = .openAI
        let openAIReply = try await service(keys: keys).reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), settings: settings)
        #expect(openAIReply.provider == .openAI)
    }
}
