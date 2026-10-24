import Foundation
import Testing
@testable import NotchPilotCore

// MARK: - URLProtocol stub

private struct StubResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    /// Delivered as separate `didLoad` calls, so the client sees split lines and characters.
    var chunks: [Data]
    /// Leaves the response open after the last chunk, like a stream still generating.
    var staysOpen = false

    init(status: Int, headers: [String: String] = [:], body: Data, chunkSize: Int? = nil, staysOpen: Bool = false) {
        self.status = status
        self.headers = headers
        self.chunks = chunkSize.map { size in
            stride(from: 0, to: body.count, by: size).map { body.subdata(in: $0..<min($0 + size, body.count)) }
        } ?? [body]
        self.staysOpen = staysOpen
    }
}

/// Intercepts every request made through `stubSession()`. The handler and captured request
/// are static, so the suite below is serialised.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _response: StubResponse?
    nonisolated(unsafe) private static var _failure: URLError?
    nonisolated(unsafe) private static var _captured: (request: URLRequest, body: Data)?
    nonisolated(unsafe) private static var _stopped = false

    static func respond(_ response: StubResponse) {
        lock.withLock { _response = response; _failure = nil; _captured = nil; _stopped = false }
    }

    static func fail(_ error: URLError) {
        lock.withLock { _response = nil; _failure = error; _captured = nil; _stopped = false }
    }

    static var captured: (request: URLRequest, body: Data)? { lock.withLock { _captured } }
    /// True once URLSession stopped the load (finished or cancelled).
    static var stopped: Bool { lock.withLock { _stopped } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { Self.lock.withLock { Self._stopped = true } }

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
        for chunk in response.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if !response.staysOpen { client?.urlProtocolDidFinishLoading(self) }
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
    func streamReply(to request: ReplyRequest, apiKey: String, settings: AssistantSettings) -> AsyncThrowingStream<ReplyEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started(model: "stub"))
            continuation.yield(.textDelta("key=\(apiKey)"))
            continuation.yield(.finished(truncated: false))
            continuation.finish()
        }
    }
}

/// An SSE body: one `event:` (when named) and one `data:` line per event.
private func sse(_ events: [(name: String?, data: Any)]) -> Data {
    var text = ""
    for event in events {
        if let name = event.name { text += "event: \(name)\n" }
        let data = (event.data as? String) ?? String(decoding: json(event.data), as: UTF8.self)
        text += "data: \(data)\n\n"
    }
    return Data(text.utf8)
}

/// A Claude stream: `message_start` naming `model`, the given middle events, then
/// `message_delta` with `stopReason` and `message_stop`.
private func claudeStream(model: String = "claude-opus-5-5", _ middle: [[String: Any]], stopReason: String = "end_turn") -> Data {
    var events: [(name: String?, data: Any)] = [
        ("message_start", ["type": "message_start", "message": ["model": model, "content": [], "stop_reason": NSNull()]]),
        ("ping", ["type": "ping"]),
    ]
    events += middle.map { ($0["type"] as? String, $0) }
    events.append(("message_delta", ["type": "message_delta", "delta": ["stop_reason": stopReason]]))
    events.append(("message_stop", ["type": "message_stop"]))
    return sse(events)
}

private func blockStart(_ index: Int, _ type: String) -> [String: Any] {
    ["type": "content_block_start", "index": index, "content_block": ["type": type]]
}
private func textDelta(_ index: Int, _ text: String) -> [String: Any] {
    ["type": "content_block_delta", "index": index, "delta": ["type": "text_delta", "text": text]]
}
private func blockStop(_ index: Int) -> [String: Any] { ["type": "content_block_stop", "index": index] }

/// OpenAI chunks then `[DONE]`.
private func openAIStream(model: String = "gpt-5-2026", _ deltas: [[String: Any]], finishReason: String = "stop") -> Data {
    var events: [(name: String?, data: Any)] = deltas.map {
        (nil, ["model": model, "choices": [["index": 0, "delta": $0, "finish_reason": NSNull()]]])
    }
    events.append((nil, ["model": model, "choices": [["index": 0, "delta": [:], "finish_reason": finishReason]]]))
    events.append((nil, "[DONE]"))
    return sse(events)
}

/// Every event a stream yielded, and the error it ended with (nil if it finished).
private func drain(_ stream: AsyncThrowingStream<ReplyEvent, Error>) async -> (events: [ReplyEvent], error: Error?) {
    var events: [ReplyEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
private let claudeOK = claudeStream([
    blockStart(0, "thinking"),
    ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "hidden"]],
    ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "sig"]],
    blockStop(0),
    blockStart(1, "text"), textDelta(1, "Hello"), blockStop(1),
    blockStart(2, "fallback"), textDelta(2, "ignored"), blockStop(2),
    blockStart(3, "text"), textDelta(3, " world"), blockStop(3),
])

// MARK: - Tests

@Suite("AI clients", .serialized)
struct AIClientTests {

    // MARK: Claude

    @Test("Claude request has the documented URL, headers and body, with stream: true")
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
        #expect(body["stream"] as? Bool == true)
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

    @Test("Claude streams started, text deltas of text blocks only, then finished")
    func claudeStreamsEvents() async throws {
        StubURLProtocol.respond(.init(status: 200, body: claudeOK))
        let (events, error) = await drain(ClaudeClient(session: stubSession())
            .streamReply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings()))
        #expect(error == nil)
        #expect(events == [.started(model: "claude-opus-5-5"), .textDelta("Hello"), .textDelta(" world"), .finished(truncated: false)])
    }

    @Test("Claude joins text blocks only and reports the response model")
    func claudeParsesText() async throws {
        StubURLProtocol.respond(.init(status: 200, body: claudeOK))
        let reply = try await ClaudeClient(session: stubSession())
            .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        #expect(reply == AssistantReply(text: "Hello world", provider: .claude, model: "claude-opus-5-5", truncated: false))
    }

    @Test("Claude stream split into tiny chunks keeps lines and multibyte characters intact", arguments: [1, 3, 7])
    func claudeChunked(chunkSize: Int) async throws {
        let body = claudeStream(model: "claude-fallback", [blockStart(0, "text"), textDelta(0, "héllo "), textDelta(0, "wörld 👋"), blockStop(0)])
        StubURLProtocol.respond(.init(status: 200, body: body, chunkSize: chunkSize))
        let reply = try await ClaudeClient(session: stubSession())
            .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        #expect(reply == AssistantReply(text: "héllo wörld 👋", provider: .claude, model: "claude-fallback", truncated: false))
    }

    @Test("Claude stop_reason refusal mid-stream throws refused and never finishes")
    func claudeRefusal() async throws {
        StubURLProtocol.respond(.init(status: 200, body: claudeStream([blockStart(0, "text"), textDelta(0, "partial"), blockStop(0)], stopReason: "refusal")))
        let (events, error) = await drain(ClaudeClient(session: stubSession())
            .streamReply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings()))
        #expect(error as? AssistantError == .refused(.claude))
        #expect(events == [.started(model: "claude-opus-5-5"), .textDelta("partial")])
    }

    @Test("Claude stop_reason max_tokens marks the reply truncated")
    func claudeTruncated() async throws {
        StubURLProtocol.respond(.init(status: 200, body: claudeStream([blockStart(0, "text"), textDelta(0, "cut"), blockStop(0)], stopReason: "max_tokens")))
        let reply = try await ClaudeClient(session: stubSession())
            .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        #expect(reply.truncated)
        #expect(reply.text == "cut")
    }

    @Test("Claude stream with no text and no truncation is invalidResponse")
    func claudeEmpty() async throws {
        StubURLProtocol.respond(.init(status: 200, body: claudeStream([blockStart(0, "text"), blockStop(0)])))
        let (events, error) = await drain(ClaudeClient(session: stubSession())
            .streamReply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings()))
        #expect(error as? AssistantError == .invalidResponse(.claude))
        #expect(!events.contains(.finished(truncated: false)))
    }

    @Test("Claude error event maps to AssistantError", arguments: [
        ("overloaded_error", AssistantError.providerUnavailable(.claude, status: 529)),
        ("api_error", AssistantError.providerUnavailable(.claude, status: 500)),
        ("rate_limit_error", AssistantError.rateLimited(.claude, retryAfterSeconds: nil)),
        ("authentication_error", AssistantError.invalidAPIKey(.claude)),
        ("invalid_request_error", AssistantError.requestRejected(.claude, status: 400, message: "bad thing")),
    ])
    func claudeErrorEvent(type: String, expected: AssistantError) async throws {
        StubURLProtocol.respond(.init(status: 200, body: sse([
            ("message_start", ["type": "message_start", "message": ["model": "claude-opus-5-5"]]),
            ("error", ["type": "error", "error": ["type": type, "message": "bad thing"]]),
        ])))
        await #expect(throws: expected) {
            try await ClaudeClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        }
    }

    @Test("Claude HTTP errors before the stream map to AssistantError", arguments: [
        (StubResponse(status: 401, body: Data()), AssistantError.invalidAPIKey(.claude)),
        (StubResponse(status: 403, body: Data()), AssistantError.invalidAPIKey(.claude)),
        (StubResponse(status: 429, headers: ["retry-after": "17"], body: Data()), AssistantError.rateLimited(.claude, retryAfterSeconds: 17)),
        (StubResponse(status: 429, body: Data()), AssistantError.rateLimited(.claude, retryAfterSeconds: nil)),
        (StubResponse(status: 529, body: Data()), AssistantError.providerUnavailable(.claude, status: 529)),
        (StubResponse(status: 503, body: Data()), AssistantError.providerUnavailable(.claude, status: 503)),
        (StubResponse(status: 400, body: json([
            "type": "error", "error": ["type": "invalid_request_error", "message": "model: not found"],
        ]), chunkSize: 5), AssistantError.requestRejected(.claude, status: 400, message: "model: not found")),
        (StubResponse(status: 400, body: json(["error": ["message": String(repeating: "x", count: 500)]])),
         AssistantError.requestRejected(.claude, status: 400, message: String(repeating: "x", count: 200))),
    ])
    fileprivate func claudeHTTPErrors(stub: StubResponse, expected: AssistantError) async throws {
        StubURLProtocol.respond(stub)
        await #expect(throws: expected) {
            try await ClaudeClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        }
    }

    @Test("Undecodable 200 body throws invalidResponse", arguments: ["not json", "data: not json\n\n"])
    func claudeUndecodable(body: String) async throws {
        StubURLProtocol.respond(.init(status: 200, body: Data(body.utf8)))
        await #expect(throws: AssistantError.invalidResponse(.claude)) {
            try await ClaudeClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        }
    }

    @Test("Claude stream that ends before message_stop throws invalidResponse")
    func claudeCutOff() async throws {
        StubURLProtocol.respond(.init(status: 200, body: sse([
            ("message_start", ["type": "message_start", "message": ["model": "claude-opus-5-5"]]),
            ("content_block_start", blockStart(0, "text")),
            ("content_block_delta", textDelta(0, "half")),
        ])))
        let (events, error) = await drain(ClaudeClient(session: stubSession())
            .streamReply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings()))
        #expect(error as? AssistantError == .invalidResponse(.claude))
        #expect(events == [.started(model: "claude-opus-5-5"), .textDelta("half")])
    }

    @Test("An SSE line over the 1 MiB limit throws invalidResponse instead of buffering forever")
    func claudeOversizedLine() async throws {
        let body = Data("event: message_start\ndata: ".utf8) + Data(repeating: UInt8(ascii: "x"), count: ServerSentEventParser.defaultLimit + 1)
        StubURLProtocol.respond(.init(status: 200, headers: ["content-type": "text/event-stream"], body: body, chunkSize: 64 * 1024))
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

    @Test("Cancelling the consumer ends the stream and cancels the request", .timeLimit(.minutes(1)))
    func cancellation() async throws {
        // Everything up to the first delta, then the connection stays open.
        let body = sse([
            ("message_start", ["type": "message_start", "message": ["model": "claude-opus-5-5"]]),
            ("content_block_start", blockStart(0, "text")),
            ("content_block_delta", textDelta(0, "Hel")),
        ])
        // The content type matters: without it URLSession holds back the first 512 bytes to
        // sniff one, and this body is shorter than that.
        StubURLProtocol.respond(.init(status: 200, headers: ["content-type": "text/event-stream"], body: body, staysOpen: true))
        let stream = ClaudeClient(session: stubSession())
            .streamReply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())

        let (delivered, deliveredContinuation) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            var events: [ReplyEvent] = []
            do {
                for try await event in stream {
                    events.append(event)
                    if event == .textDelta("Hel") { deliveredContinuation.yield() }
                }
            } catch {}
            return events
        }
        for await _ in delivered { break }
        consumer.cancel()
        let events = await consumer.value
        #expect(events == [.started(model: "claude-opus-5-5"), .textDelta("Hel")])

        // URLSession stops the load asynchronously after the task is cancelled.
        for _ in 0..<500 where !StubURLProtocol.stopped {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(StubURLProtocol.stopped)
    }

    // MARK: OpenAI

    @Test("OpenAI request has the documented URL, headers and body, with stream: true")
    func openAIRequestShape() async throws {
        StubURLProtocol.respond(.init(status: 200, body: openAIStream([["role": "assistant", "content": ""], ["content": "Hi"]])))
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
        #expect(body["stream"] as? Bool == true)
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

    @Test("OpenAI streams started, deltas and finished at [DONE], across split chunks", arguments: [nil, 2] as [Int?])
    func openAIStreamsEvents(chunkSize: Int?) async throws {
        StubURLProtocol.respond(.init(status: 200, body: openAIStream([["role": "assistant", "content": ""], ["content": "Grüß"], ["content": " 👋"]]), chunkSize: chunkSize))
        let (events, error) = await drain(OpenAIClient(session: stubSession())
            .streamReply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings()))
        #expect(error == nil)
        #expect(events == [.started(model: "gpt-5-2026"), .textDelta("Grüß"), .textDelta(" 👋"), .finished(truncated: false)])
    }

    @Test("OpenAI stream without [DONE] throws invalidResponse")
    func openAINoDone() async throws {
        StubURLProtocol.respond(.init(status: 200, body: sse([(nil, ["model": "gpt-5", "choices": [["delta": ["content": "Hi"], "finish_reason": "stop"]]])])))
        await #expect(throws: AssistantError.invalidResponse(.openAI)) {
            try await OpenAIClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        }
    }

    @Test("OpenAI refusal delta or content_filter throws refused and never finishes", arguments: [
        openAIStream([["content": "par"], ["refusal": "No."]]),
        openAIStream([["content": "par"]], finishReason: "content_filter"),
    ])
    func openAIRefusal(body: Data) async throws {
        StubURLProtocol.respond(.init(status: 200, body: body))
        let (events, error) = await drain(OpenAIClient(session: stubSession())
            .streamReply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings()))
        #expect(error as? AssistantError == .refused(.openAI))
        #expect(events == [.started(model: "gpt-5-2026"), .textDelta("par")])
    }

    @Test("OpenAI blank content on a complete reply is not returned as a blank reply")
    func openAIEmptyContent() async throws {
        StubURLProtocol.respond(.init(status: 200, body: openAIStream([["role": "assistant", "content": ""], ["content": " \n"]])))
        await #expect(throws: AssistantError.invalidResponse(.openAI)) {
            try await OpenAIClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        }
    }

    @Test("OpenAI with no text and finish_reason length finishes truncated, like Claude")
    func openAIEmptyTruncated() async throws {
        StubURLProtocol.respond(.init(status: 200, body: openAIStream([["role": "assistant", "content": ""]], finishReason: "length")))
        let (events, error) = await drain(OpenAIClient(session: stubSession())
            .streamReply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings()))
        #expect(error == nil)
        #expect(events == [.started(model: "gpt-5-2026"), .finished(truncated: true)])

        StubURLProtocol.respond(.init(status: 200, body: claudeStream([blockStart(0, "text"), blockStop(0)], stopReason: "max_tokens")))
        let claudeReply = try await ClaudeClient(session: stubSession())
            .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        #expect(claudeReply == AssistantReply(text: "", provider: .claude, model: "claude-opus-5-5", truncated: true))
    }

    @Test("OpenAI finish_reason length marks the reply truncated")
    func openAITruncated() async throws {
        StubURLProtocol.respond(.init(status: 200, body: openAIStream([["content": "cut"]], finishReason: "length")))
        let reply = try await OpenAIClient(session: stubSession())
            .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        #expect(reply.truncated)
        #expect(reply.text == "cut")
    }

    @Test("OpenAI error object mid-stream maps to AssistantError", arguments: [
        (["message": "boom", "type": "server_error"], AssistantError.providerUnavailable(.openAI, status: 500)),
        (["message": "slow down", "type": "requests", "code": "rate_limit_exceeded"], AssistantError.rateLimited(.openAI, retryAfterSeconds: nil)),
        (["message": "too long", "type": "invalid_request_error"], AssistantError.requestRejected(.openAI, status: 400, message: "too long")),
    ])
    func openAIStreamError(error: [String: String], expected: AssistantError) async throws {
        StubURLProtocol.respond(.init(status: 200, body: sse([
            (nil, ["model": "gpt-5", "choices": [["delta": ["content": "Hi"], "finish_reason": NSNull()]]]),
            (nil, ["error": error]),
        ])))
        await #expect(throws: expected) {
            try await OpenAIClient(session: stubSession())
                .reply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), apiKey: "k", settings: AssistantSettings())
        }
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
        let request = ReplyRequest(transcript: "  \n", question: " ", systemPrompt: "s")
        await #expect(throws: AssistantError.nothingToSend) {
            try await service(keys: [.claude: "k"]).reply(to: request, settings: AssistantSettings())
        }
        #expect(throws: AssistantError.nothingToSend) {
            _ = try service(keys: [.claude: "k"]).streamReply(to: request, settings: AssistantSettings())
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
        #expect(throws: AssistantError.missingAPIKey(.openAI)) {
            _ = try service(keys: [.claude: "k"]).streamReply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), settings: settings)
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

        let (events, error) = await drain(try service(keys: keys).streamReply(to: ReplyRequest(transcript: "t", systemPrompt: "s"), settings: settings))
        #expect(error == nil)
        #expect(events == [.started(model: "stub"), .textDelta("key=o-key"), .finished(truncated: false)])
    }
}
