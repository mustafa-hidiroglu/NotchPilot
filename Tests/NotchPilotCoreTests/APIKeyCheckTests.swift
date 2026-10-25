import Foundation
import Testing
@testable import NotchPilotCore

@Suite("Check Key request")
struct APIKeyCheckTests {
    private struct Keys: APIKeyStoring {
        var keys: [AIProvider: String]
        func apiKey(for provider: AIProvider) throws -> String? { keys[provider] }
        func setAPIKey(_ key: String, for provider: AIProvider) throws {}
        func removeAPIKey(for provider: AIProvider) throws {}
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [ReplyRequest] = []
        private var _efforts: [String] = []
        private var _terminated = false
        func record(_ request: ReplyRequest, effort: String) { lock.withLock { _requests.append(request); _efforts.append(effort) } }
        func markTerminated() { lock.withLock { _terminated = true } }
        var requests: [ReplyRequest] { lock.withLock { _requests } }
        var efforts: [String] { lock.withLock { _efforts } }
        var terminated: Bool { lock.withLock { _terminated } }
    }

    /// Yields `.started` and then stays open, like a provider still generating.
    private struct OpenStreamClient: ReplyGenerating {
        let provider = AIProvider.claude
        let log: Log
        func streamReply(to request: ReplyRequest, apiKey: String, settings: AssistantSettings) -> AsyncThrowingStream<ReplyEvent, Error> {
            log.record(request, effort: settings.claudeEffort)
            return AsyncThrowingStream { continuation in
                continuation.yield(.started(model: "stub"))
                continuation.onTermination = { _ in log.markTerminated() }
            }
        }
    }

    private struct FailingClient: ReplyGenerating {
        let provider: AIProvider
        let error: AssistantError
        func streamReply(to request: ReplyRequest, apiKey: String, settings: AssistantSettings) -> AsyncThrowingStream<ReplyEvent, Error> {
            AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    @Test("sends one minimal request with no transcript, screenshot or history, then stops reading")
    func minimalRequest() async throws {
        let log = Log()
        let service = ReplyService(keyStore: Keys(keys: [.claude: "k"]), claude: OpenStreamClient(log: log),
                                   openAI: FailingClient(provider: .openAI, error: .nothingToSend))
        var settings = AssistantSettings()
        settings.claudeEffort = "high"
        try await APIKeyCheck.run(with: service, settings: settings)

        let request = try #require(log.requests.first)
        #expect(log.requests.count == 1)
        #expect(request.transcript.isEmpty)
        #expect(request.screenshotJPEG == nil)
        #expect(request.history.isEmpty)
        #expect(request.question == APIKeyCheck.question)
        #expect(request.systemPrompt == APIKeyCheck.systemPrompt)
        #expect(log.efforts == ["low"])
        #expect(log.terminated)   // the stream was ended, which cancels a real request
    }

    @Test("provider errors and a missing key come back as AssistantError")
    func errors() async {
        let service = ReplyService(keyStore: Keys(keys: [.openAI: "k"]),
                                   claude: FailingClient(provider: .claude, error: .invalidAPIKey(.claude)),
                                   openAI: FailingClient(provider: .openAI, error: .invalidAPIKey(.openAI)))
        var settings = AssistantSettings()
        settings.provider = .openAI
        await #expect(throws: AssistantError.invalidAPIKey(.openAI)) {
            try await APIKeyCheck.run(with: service, settings: settings)
        }
        settings.provider = .claude
        await #expect(throws: AssistantError.missingAPIKey(.claude)) {
            try await APIKeyCheck.run(with: service, settings: settings)
        }
    }
}
