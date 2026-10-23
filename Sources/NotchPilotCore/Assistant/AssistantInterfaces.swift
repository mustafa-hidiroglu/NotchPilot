import Foundation

// Shared contracts for the assistant features (speech-to-text, AI replies, on-demand
// screenshots). Implementations live in Speech/, AI/ and Screenshot/; the app target only
// depends on these types.
//
// Privacy model (README › Permissions and privacy):
//  * Transcription is on-device only. Audio never leaves the Mac.
//  * Nothing is sent over the network until the person presses Ask. Then exactly one
//    request goes to the provider they chose, containing the transcript text and, only if
//    they ticked it, one screenshot.
//  * API keys live in the Keychain. Transcripts and screenshots live in memory only.

// MARK: - Providers and settings

public enum AIProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case openAI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "ChatGPT"
        }
    }
}

/// Non-secret assistant preferences (persisted in UserDefaults by the app). API keys are
/// never part of this type.
public struct AssistantSettings: Codable, Sendable, Equatable {
    public var provider: AIProvider = .claude
    public var claudeModel = "claude-opus-5-5"
    /// `output_config.effort` for Claude: low | medium | high | xhigh | max.
    public var claudeEffort = "low"
    public var openAIModel = "gpt-5"
    /// Instruction sent with every request.
    public var systemPrompt = """
        You are NotchPilot, a concise assistant on a Mac. You receive a live transcript of \
        audio the Mac is playing (for example a call, lecture or video) and, sometimes, a \
        screenshot. Answer the person's need from that context in a few short sentences or \
        bullets. If the transcript is unclear, say what is missing.
        """
    /// Ticked by default for "Include Screen" next to Ask.
    public var includeScreenshotByDefault = false
    /// How much recent transcript to send with a request.
    public var transcriptCharacterLimit = 6_000

    public init() {}

    // Tolerant decoding: settings saved by an older or newer build (missing keys, unknown
    // provider) keep every value that is still readable instead of resetting everything.
    private enum CodingKeys: String, CodingKey {
        case provider, claudeModel, claudeEffort, openAIModel, systemPrompt
        case includeScreenshotByDefault, transcriptCharacterLimit
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try? c.decodeIfPresent(String.self, forKey: .provider), let value = AIProvider(rawValue: raw) {
            provider = value
        }
        claudeModel = (try? c.decodeIfPresent(String.self, forKey: .claudeModel)) ?? claudeModel
        claudeEffort = (try? c.decodeIfPresent(String.self, forKey: .claudeEffort)) ?? claudeEffort
        openAIModel = (try? c.decodeIfPresent(String.self, forKey: .openAIModel)) ?? openAIModel
        systemPrompt = (try? c.decodeIfPresent(String.self, forKey: .systemPrompt)) ?? systemPrompt
        includeScreenshotByDefault = (try? c.decodeIfPresent(Bool.self, forKey: .includeScreenshotByDefault)) ?? includeScreenshotByDefault
        transcriptCharacterLimit = (try? c.decodeIfPresent(Int.self, forKey: .transcriptCharacterLimit)) ?? transcriptCharacterLimit
    }
}

// MARK: - Replies

public struct ReplyRequest: Sendable, Equatable {
    public var transcript: String
    /// Optional question typed by the person; nil means "respond to the transcript".
    public var question: String?
    /// JPEG bytes of one on-demand screenshot, or nil.
    public var screenshotJPEG: Data?
    public var systemPrompt: String

    public init(transcript: String, question: String? = nil, screenshotJPEG: Data? = nil, systemPrompt: String) {
        self.transcript = transcript
        self.question = question
        self.screenshotJPEG = screenshotJPEG
        self.systemPrompt = systemPrompt
    }
}

public struct AssistantReply: Sendable, Equatable {
    public var text: String
    public var provider: AIProvider
    /// Model that produced the reply, as reported by the API.
    public var model: String
    /// True when the reply was cut off by the output limit.
    public var truncated: Bool

    public init(text: String, provider: AIProvider, model: String, truncated: Bool = false) {
        self.text = text
        self.provider = provider
        self.model = model
        self.truncated = truncated
    }
}

public enum AssistantError: Error, Sendable, Equatable {
    case missingAPIKey(AIProvider)
    case invalidAPIKey(AIProvider)
    case rateLimited(AIProvider, retryAfterSeconds: Double?)
    case providerUnavailable(AIProvider, status: Int)
    case requestRejected(AIProvider, status: Int, message: String)
    /// The model declined to answer (Claude `stop_reason: "refusal"`, OpenAI refusal).
    case refused(AIProvider)
    case network(String)
    case invalidResponse(AIProvider)
    case nothingToSend
    case keychain(OSStatus)

    public var title: String {
        switch self {
        case .missingAPIKey: "API Key Needed"
        case .invalidAPIKey: "API Key Not Accepted"
        case .rateLimited: "Rate Limited"
        case .providerUnavailable: "Service Unavailable"
        case .requestRejected: "Request Not Accepted"
        case .refused: "No Reply"
        case .network: "No Connection"
        case .invalidResponse: "Unexpected Reply"
        case .nothingToSend: "Nothing to Send Yet"
        case .keychain: "Keychain Error"
        }
    }

    public var message: String {
        switch self {
        case .missingAPIKey(let provider):
            "Add your \(provider.displayName) API key in NotchPilot Settings."
        case .invalidAPIKey(let provider):
            "\(provider.displayName) didn’t accept the API key. Check it in NotchPilot Settings."
        case .rateLimited(let provider, let retryAfter):
            if let retryAfter { "\(provider.displayName) is rate-limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s." }
            else { "\(provider.displayName) is rate-limiting requests. Try again shortly." }
        case .providerUnavailable(let provider, _):
            "\(provider.displayName) is temporarily unavailable. Try again shortly."
        case .requestRejected(let provider, _, _):
            "\(provider.displayName) didn’t accept the request. Check the model name in NotchPilot Settings."
        case .refused(let provider):
            "\(provider.displayName) declined to answer this request."
        case .network:
            "NotchPilot couldn’t reach the service. Check your internet connection, then ask again."
        case .invalidResponse(let provider):
            "\(provider.displayName) sent a reply NotchPilot couldn’t read."
        case .nothingToSend:
            "Start capture and let some speech come through, or type a question."
        case .keychain:
            "NotchPilot couldn’t access the Keychain. Try saving the key again."
        }
    }

    /// Raw detail for a tooltip; never shown as the main message.
    public var technicalDetail: String? {
        switch self {
        case .requestRejected(_, let status, let message): "HTTP \(status): \(message)"
        case .providerUnavailable(_, let status): "HTTP \(status)"
        case .network(let detail): detail
        case .keychain(let status): "OSStatus \(status)"
        default: nil
        }
    }
}

/// One provider's HTTP client. Implementations: `ClaudeClient`, `OpenAIClient`.
public protocol ReplyGenerating: Sendable {
    var provider: AIProvider { get }
    func reply(to request: ReplyRequest, apiKey: String, settings: AssistantSettings) async throws -> AssistantReply
}

/// Secret storage for provider API keys. Implementation: `KeychainAPIKeyStore`.
public protocol APIKeyStoring: Sendable {
    func apiKey(for provider: AIProvider) throws -> String?
    func setAPIKey(_ key: String, for provider: AIProvider) throws
    func removeAPIKey(for provider: AIProvider) throws
}

// MARK: - Transcription

public enum TranscriptionState: Sendable, Equatable {
    case off
    case needsPermission
    case permissionDenied
    /// On-device recognition is not available for this language/Mac; never falls back
    /// to server-based recognition.
    case unavailable(String)
    case listening
    case failed(String)
}

/// A rolling, in-memory transcript. `finalText` holds completed utterances; `partialText`
/// the utterance currently being recognised.
public struct Transcript: Sendable, Equatable {
    public var finalText: String = ""
    public var partialText: String = ""

    public init(finalText: String = "", partialText: String = "") {
        self.finalText = finalText
        self.partialText = partialText
    }

    public var fullText: String {
        partialText.isEmpty ? finalText : (finalText.isEmpty ? partialText : finalText + " " + partialText)
    }

    /// The last `limit` characters of the full text, cut at a word boundary when possible.
    public func recentText(limit: Int) -> String {
        let text = fullText
        guard limit > 0 else { return "" }   // the limit is persisted in UserDefaults; never trap on bad values
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        // Drop the leading fragment only when the cut landed inside a word.
        let cutsWord = !text[text.index(before: tail.startIndex)].isWhitespace
        if cutsWord, let space = tail.firstIndex(of: " ") { return String(tail[tail.index(after: space)...]) }
        return String(tail)
    }
}

// MARK: - Screenshots

public enum ScreenshotError: Error, Sendable, Equatable {
    case permissionDenied
    case noDisplay
    case captureFailed(String)
    case encodingFailed
}

/// One on-demand capture of the main display, returned as JPEG bytes. Never written to
/// disk. Implementation: `ScreenshotCapturer`.
public protocol ScreenshotCapturing: Sendable {
    func captureMainDisplayJPEG(maxLongEdge: Int, quality: Double) async throws -> Data
}
