import Foundation

// Shared contracts for the assistant features (speech-to-text, AI replies, on-demand
// screenshots). Implementations live in Speech/, AI/ and Screenshot/; the app target only
// depends on these types.
//
// Privacy model (README › Permissions and privacy):
//  * Transcription is on-device only (whisper.cpp). Audio never leaves the Mac. The only
//    speech-related network use is downloading a model file once, when the person asks.
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
    /// `SpeechModel.id` of the whisper model to transcribe with. Defaults to one sized for
    /// this Mac's chip (see `SpeechModel.recommendedID`).
    public var speechModelID = SpeechModel.recommendedID
    /// Whisper language code ("en", "de", …) or "auto" to detect it.
    public var speechLanguage = "auto"
    /// Global keyboard shortcut that opens the island ready to Ask.
    public var askHotKeyEnabled = true
    public var askHotKey = HotKey.defaultAsk

    public init() {}

    // Tolerant decoding: settings saved by an older or newer build (missing keys, unknown
    // provider) keep every value that is still readable instead of resetting everything.
    private enum CodingKeys: String, CodingKey {
        case provider, claudeModel, claudeEffort, openAIModel, systemPrompt
        case includeScreenshotByDefault, transcriptCharacterLimit
        case speechModelID, speechLanguage, askHotKeyEnabled, askHotKey
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
        if let id = try? c.decodeIfPresent(String.self, forKey: .speechModelID), SpeechModel.catalog.contains(where: { $0.id == id }) {
            speechModelID = id
        }
        speechLanguage = (try? c.decodeIfPresent(String.self, forKey: .speechLanguage)) ?? speechLanguage
        askHotKeyEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .askHotKeyEnabled)) ?? askHotKeyEnabled
        askHotKey = (try? c.decodeIfPresent(HotKey.self, forKey: .askHotKey)) ?? askHotKey
    }
}

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags
/// (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`), as `RegisterEventHotKey` takes them.
public struct HotKey: Codable, Sendable, Equatable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// ⇧⌘Space. Not bound by macOS by default; ⌃⌥Space switches input sources, ⌘Space is
    /// Spotlight, and ⌥Space is taken by the ChatGPT and Raycast apps.
    public static let defaultAsk = HotKey(keyCode: 49 /* kVK_Space */, carbonModifiers: 0x0100 /* cmdKey */ | 0x0200 /* shiftKey */)
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

/// One step of a streamed reply.
public enum ReplyEvent: Sendable, Equatable {
    /// The provider accepted the request; `model` is the model actually serving it.
    case started(model: String)
    /// More reply text, to append to what came before.
    case textDelta(String)
    /// The reply is complete. `truncated` is true when the output limit cut it off.
    case finished(truncated: Bool)
}

/// One provider's HTTP client. Implementations: `ClaudeClient`, `OpenAIClient`.
///
/// The stream yields `.started`, any number of `.textDelta`, then exactly one `.finished`,
/// or ends by throwing an `AssistantError` (a refusal mid-stream throws `.refused`; the
/// caller discards the partial text). Cancelling the consuming task cancels the request.
public protocol ReplyGenerating: Sendable {
    var provider: AIProvider { get }
    func streamReply(to request: ReplyRequest, apiKey: String, settings: AssistantSettings) -> AsyncThrowingStream<ReplyEvent, Error>
}

extension ReplyGenerating {
    /// Collects a streamed reply into one value.
    public func reply(to request: ReplyRequest, apiKey: String, settings: AssistantSettings) async throws -> AssistantReply {
        try await AssistantReply.collect(streamReply(to: request, apiKey: apiKey, settings: settings), provider: provider)
    }
}

extension AssistantReply {
    /// Folds a reply stream into one value. Throws `.invalidResponse` for a stream that ends
    /// without `.finished`, or finishes with no text and no truncation.
    public static func collect(_ events: AsyncThrowingStream<ReplyEvent, Error>, provider: AIProvider) async throws -> AssistantReply {
        var model = ""
        var text = ""
        for try await event in events {
            switch event {
            case .started(let name): model = name
            case .textDelta(let delta): text += delta
            case .finished(let truncated):
                guard !text.isEmpty || truncated else { throw AssistantError.invalidResponse(provider) }
                return AssistantReply(text: text, provider: provider, model: model, truncated: truncated)
            }
        }
        throw AssistantError.invalidResponse(provider)
    }
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
    /// The selected whisper model is not downloaded yet (Settings › Speech offers it).
    case needsModel
    /// The model file is being loaded into memory (a second or two on first start).
    case loadingModel
    /// The model could not be used, e.g. a damaged file; the string is shown to the person.
    case unavailable(String)
    case listening
    case failed(String)
}

/// Turns captured system audio into a rolling transcript. Implementation: `WhisperTranscriber`.
///
/// Also a `PCMBlockProcessor`: plug it into `AudioCaptureService(processor:)` and keep a
/// strong reference (the service holds its processor weakly).
public protocol SystemAudioTranscribing: PCMBlockProcessor, Sendable {
    /// Newest state wins; starts with `.off`.
    var states: AsyncStream<TranscriptionState> { get }
    /// Newest transcript wins; starts empty.
    var transcripts: AsyncStream<Transcript> { get }
    /// Starts listening with the model in `settings` (loading it if needed). Calling it
    /// while listening with the same model and language does nothing; with different ones
    /// it switches.
    func start(model: SpeechModel, language: String)
    /// Stops listening. The utterance in progress is kept as final text.
    func stop()
    /// Forgets the transcript.
    func clear()
}

// MARK: - Speech models

/// A whisper.cpp ggml model that can be downloaded from Hugging Face.
public struct SpeechModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    /// One line for Settings, e.g. "Fastest, least accurate."
    public let summary: String
    public let fileName: String
    public let sizeBytes: Int64
    /// Lower-case hex SHA-256 of the file; a download that doesn't match is discarded.
    public let sha256: String

    /// Pinned to one commit of the Hugging Face repository, so the file behind the URL
    /// can't change (the SHA-256 check would reject it anyway). Redirects to the
    /// Hugging Face CDN (*.hf.co).
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/\(fileName)")!
    }

    /// Multilingual models only, so `speechLanguage` can be anything whisper supports.
    public static let catalog: [SpeechModel] = [
        SpeechModel(id: "tiny", displayName: "Tiny", summary: "Fastest, least accurate. About 250 MB while transcribing.",
                    fileName: "ggml-tiny.bin", sizeBytes: 77_691_713,
                    sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
        SpeechModel(id: "base", displayName: "Base", summary: "Fast and accurate enough for most speech. About 350 MB while transcribing.",
                    fileName: "ggml-base.bin", sizeBytes: 147_951_465,
                    sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        SpeechModel(id: "small", displayName: "Small", summary: "More accurate, slower to update. About 800 MB while transcribing.",
                    fileName: "ggml-small.bin", sizeBytes: 487_601_967,
                    sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        SpeechModel(id: "large-v3-turbo", displayName: "Large Turbo", summary: "Most accurate, slowest to update. About 800 MB while transcribing.",
                    fileName: "ggml-large-v3-turbo-q5_0.bin", sizeBytes: 574_041_195,
                    sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
    ]

    /// Real-time on every Apple silicon Mac, including an 8 GB M1 Air, and accurate enough
    /// for most speech.
    public static let recommendedID = "base"

    // Memory figures in the summaries were measured on Apple silicon with the app's own
    // footprint (phys_footprint) while transcribing; loading peaks briefly higher (about
    // 0.45 GB for Base, 1.2–1.3 GB for Small and Large Turbo). Every model runs on an 8 GB
    // Mac; the slowest one is flagged there because it competes hardest with other apps.

    /// Memory a model is best run with next to other apps, or nil when any Apple silicon
    /// Mac (8 GB and up) is comfortable.
    public var recommendedMemoryGB: Int? { id == "large-v3-turbo" ? 16 : nil }

    /// False when this Mac has less memory than `recommendedMemoryGB`.
    public var fitsThisMac: Bool {
        guard let minimum = recommendedMemoryGB else { return true }
        // Macs report slightly under their nominal size; compare against 15/16 of it.
        return ProcessInfo.processInfo.physicalMemory >= UInt64(minimum) * 1_073_741_824 / 16 * 15
    }

    public static func named(_ id: String) -> SpeechModel? { catalog.first { $0.id == id } }
}

public enum SpeechModelInstallState: Sendable, Equatable {
    case notInstalled
    case downloading(fraction: Double)
    case installed
    case failed(String)
}

/// Downloads, verifies, stores and deletes speech models. Implementation: `SpeechModelStore`
/// (files under ~/Library/Application Support/NotchPilot/Models).
public protocol SpeechModelManaging: Sendable {
    /// Install state of every catalog model; newest snapshot wins; starts with the current one.
    var installStates: AsyncStream<[SpeechModel.ID: SpeechModelInstallState]> { get }
    /// Path of the verified model file, or nil when it isn't installed.
    func installedFileURL(for model: SpeechModel) -> URL?
    /// Downloads and verifies the model. Progress is published on `installStates`.
    /// Cancelling the calling task cancels the download.
    func download(_ model: SpeechModel) async throws
    func delete(_ model: SpeechModel) throws
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
