import Foundation

/// HTTP plumbing shared by `ClaudeClient` and `OpenAIClient`. Never logs keys, transcripts
/// or bodies.
enum ProviderHTTP {
    static let timeout: TimeInterval = 120

    /// Ephemeral, cache-free session: nothing about a request is written to disk.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration)
    }()

    /// The user-turn text sent to either provider.
    static func composedText(for request: ReplyRequest) -> String {
        var text = "Transcript of audio playing on my Mac (most recent last):\n\(request.transcript)"
        if let question = request.question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
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

    /// Sends `request` and returns the body of a 2xx response; every other outcome becomes an
    /// `AssistantError` (or `CancellationError` when the task was cancelled).
    static func send(_ request: URLRequest, session: URLSession, provider: AIProvider) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AssistantError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AssistantError.invalidResponse(provider) }
        if let error = error(for: http, body: data, provider: provider) { throw error }
        return data
    }

    static func error(for response: HTTPURLResponse, body: Data, provider: AIProvider) -> AssistantError? {
        let status = response.statusCode
        switch status {
        case 200..<300:
            return nil
        case 401, 403:
            return .invalidAPIKey(provider)
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "retry-after")
                .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(provider, retryAfterSeconds: retryAfter)
        case 500, 502, 503, 529:
            return .providerUnavailable(provider, status: status)
        default:
            // Both providers wrap errors as {"error": {"message": ...}}.
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error.message
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            return .requestRejected(provider, status: status, message: message)
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { var message: String }
        var error: Detail
    }
}
