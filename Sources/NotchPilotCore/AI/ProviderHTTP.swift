import Foundation

/// HTTP plumbing shared by `ClaudeClient` and `OpenAIClient`. Never logs keys, transcripts
/// or bodies.
enum ProviderHTTP {
    /// Idle timeout: the longest wait for the next bytes of a reply. Replies stream, but the
    /// first text can still take a while at higher effort, so this stays generous.
    static let timeout: TimeInterval = 600
    /// The most of a non-2xx body read for its error message.
    static let maxErrorBodyBytes = 16_384

    /// Ephemeral, cache-free session: nothing about a request is written to disk.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration)
    }()

    /// The new user turn's text sent to either provider. Chat follow-ups carry the latest
    /// transcript too, so the model sees what was said since the previous turn.
    static func composedText(for request: ReplyRequest) -> String {
        var text = "Transcript of audio playing on my Mac (most recent last):\n\(request.transcript)"
        if request.purpose == .summary {
            text += """
                \n\nSummarize this transcript. Use these parts, in this order: a one-line gist; key \
                points as bullets; decisions; action items, with the owner when one is named; open \
                questions. Leave out any part that would be empty. Keep it short, and write in the \
                same language as the transcript.
                """
        } else if let question = request.question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
            text += "\n\nMy question: \(question)"
        } else {
            text += "\n\nRespond helpfully to what's being said."
        }
        return text
    }

    static func jsonRequest(url: URL, headers: [String: String], body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Sends `request` and turns its `text/event-stream` body into reply events through
    /// `decoder`. Enforces the `ReplyGenerating` contract: exactly one `.finished` or a thrown
    /// `AssistantError`; a reply that finishes with no text and no truncation, or a body that
    /// ends before finishing, is `.invalidResponse`. Ending the stream cancels the request.
    static func replyStream(
        _ request: URLRequest,
        session: URLSession,
        provider: AIProvider,
        decoder: some ReplyStreamDecoding
    ) -> AsyncThrowingStream<ReplyEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await pump(request, session: session, provider: provider, decoder: decoder, into: continuation)
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: error.code == .cancelled
                        ? CancellationError() : AssistantError.network(error.localizedDescription))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func pump(
        _ request: URLRequest,
        session: URLSession,
        provider: AIProvider,
        decoder: some ReplyStreamDecoding,
        into continuation: AsyncThrowingStream<ReplyEvent, Error>.Continuation
    ) async throws {
        // `bytes(for:)` cancels the underlying data task when this task is cancelled.
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AssistantError.invalidResponse(provider) }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= maxErrorBodyBytes { break }
            }
            throw error(for: http, body: body, provider: provider) ?? AssistantError.invalidResponse(provider)
        }

        var decoder = decoder
        var parser = ServerSentEventParser()
        var hasText = false
        // Yields the events for one SSE event; true once the reply has finished.
        func deliver(_ event: ServerSentEvent) throws -> Bool {
            for reply in try decoder.decode(event) {
                switch reply {
                case .started:
                    continuation.yield(reply)
                case .textDelta(let text):
                    guard !text.isEmpty else { continue }
                    hasText = true
                    continuation.yield(reply)
                case .finished(let truncated):
                    guard hasText || truncated else { throw AssistantError.invalidResponse(provider) }
                    continuation.yield(reply)
                    return true
                }
            }
            return false
        }

        do {
            for try await byte in bytes {
                if let event = try parser.feed(byte), try deliver(event) { return }
            }
            if let event = try parser.finish(), try deliver(event) { return }
        } catch is ServerSentEventParser.TooLarge {
            throw AssistantError.invalidResponse(provider)
        }
        try Task.checkCancellation()
        throw AssistantError.invalidResponse(provider)
    }

    static func error(for response: HTTPURLResponse, body: Data, provider: AIProvider) -> AssistantError? {
        let retryAfter = response.value(forHTTPHeaderField: "retry-after")
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        // Both providers wrap errors as {"error": {"message": ...}}.
        let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error.message
        return error(status: response.statusCode, retryAfter: retryAfter, message: message, provider: provider)
    }

    /// Maps an HTTP status, or the status equivalent of an error that arrived mid-stream.
    static func error(status: Int, retryAfter: Double? = nil, message: String?, provider: AIProvider) -> AssistantError? {
        switch status {
        case 200..<300:
            return nil
        case 401, 403:
            return .invalidAPIKey(provider)
        case 429:
            return .rateLimited(provider, retryAfterSeconds: retryAfter)
        case 408, 500, 502, 503, 504, 529:
            return .providerUnavailable(provider, status: status)
        default:
            let message = message ?? HTTPURLResponse.localizedString(forStatusCode: status)
            // Shown only as a tooltip; capped so a verbose error body can't flood the UI.
            return .requestRejected(provider, status: status, message: String(message.prefix(200)))
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { var message: String }
        var error: Detail
    }
}

/// Turns one provider's server-sent events into reply events.
protocol ReplyStreamDecoding: Sendable {
    /// The reply events carried by `event` (often none), or a thrown `AssistantError`.
    mutating func decode(_ event: ServerSentEvent) throws -> [ReplyEvent]
}
