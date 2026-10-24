import CryptoKit
import Foundation
import os
import whisper

/// Thread-safe flag that asks a running `whisper_full` to stop early through its abort
/// callback. whisper checks it between computation steps, so the run ends at the next
/// step boundary; work already submitted to the GPU (a Metal command buffer) still runs
/// to completion first. Cancellation is prompt, not instantaneous.
final class InferenceCancellation: @unchecked Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
}

/// One loaded whisper.cpp model. Owns the C context and frees it on deinit.
///
/// Not thread-safe (whisper contexts aren't): `WhisperTranscriber` creates, uses and
/// releases it on its inference queue only. Every call blocks for as long as whisper runs.
final class WhisperContext {
    let modelID: String
    private let context: OpaquePointer

    /// Silences whisper.cpp / ggml logging (it writes to stderr by default).
    private static let quietLogs: Void = {
        whisper_log_set({ _, _, _ in }, nil)
    }()

    enum LoadError: Error, Equatable {
        /// The file couldn't be read.
        case unreadable
        /// The bytes don't match the catalog's SHA-256 (damaged or replaced since download).
        case damaged
        /// The hash matched but whisper refused the model.
        case rejected
    }

    /// Loads `model` from `fileURL`. Uses Metal on Apple silicon and the CPU on Intel.
    ///
    /// The exact bytes whisper parses are hashed first: the file is read into memory once
    /// (no mapping, so it can't change between check and use), its SHA-256 compared with
    /// `model.sha256`, and only then handed to whisper, which copies the weights into its
    /// own buffers. The read copy is released as soon as init returns. Peak memory during
    /// load is therefore about twice the file size (up to ~1 GB for Small, ~1.1 GB for
    /// Large Turbo), for a second or two; steady state is whisper's copy alone.
    init(model: SpeechModel, fileURL: URL) throws(LoadError) {
        _ = Self.quietLogs
        var params = whisper_context_default_params()
        #if arch(arm64)
        params.use_gpu = true
        #else
        params.use_gpu = false
        #endif
        let loaded: OpaquePointer? = try autoreleasepool { () throws(LoadError) -> OpaquePointer? in
            // `var` so the mutable-pointer call below needs no second copy (whisper takes a
            // non-const pointer but only reads through it).
            guard var bytes = try? Data(contentsOf: fileURL, options: []) else { throw .unreadable }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard digest == model.sha256 else { throw .damaged }
            return bytes.withUnsafeMutableBytes { buffer in
                buffer.baseAddress.flatMap { whisper_init_from_buffer_with_params($0, buffer.count, params) }
            }
        }
        guard let loaded else { throw .rejected }
        context = loaded
        modelID = model.id
    }

    deinit {
        whisper_free(context)
    }

    struct Transcription: Equatable {
        var text: String
        /// Language code whisper used ("en", "de", …): the detected one when asked for "auto".
        var language: String?
    }

    /// Transcribes 16 kHz mono audio as one segment of plain text. Returns nil when whisper
    /// fails or `cancellation` fires mid-run.
    ///
    /// `partial` passes skip whisper's temperature fallback (re-decoding at higher
    /// temperatures when the output looks unreliable): a partial is replaced a second later
    /// anyway, and the fallback can multiply its cost. Final passes keep it.
    func transcribe(_ samples: [Float], language: String, partial: Bool, threads: Int,
                    cancellation: InferenceCancellation) -> Transcription? {
        guard !cancellation.isCancelled else { return nil }
        // whisper.cpp ignores input shorter than one second; pad with silence.
        var audio = samples
        let minimum = 16_000 + 1_600
        if audio.count < minimum { audio.append(contentsOf: repeatElement(0, count: minimum - audio.count)) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(threads)
        params.no_context = true
        params.no_timestamps = true
        params.single_segment = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true
        params.translate = false
        params.detect_language = false
        if partial { params.temperature_inc = 0 }
        params.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<InferenceCancellation>.fromOpaque(data).takeUnretainedValue().isCancelled
        }

        let status: Int32 = withExtendedLifetime(cancellation) {
            params.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
            // "auto" makes whisper detect the language for this run (an extra encoder pass).
            return language.withCString { languagePointer in
                params.language = languagePointer
                return audio.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        guard status == 0, !cancellation.isCancelled else { return nil }

        var text = ""
        for segment in 0..<whisper_full_n_segments(context) {
            if let piece = whisper_full_get_segment_text(context, segment) {
                text += String(cString: piece)
            }
        }
        let languageID = whisper_full_lang_id(context)
        let detected = languageID >= 0 ? whisper_lang_str(languageID).map { String(cString: $0) } : nil
        return Transcription(text: text.trimmingCharacters(in: .whitespacesAndNewlines), language: detected)
    }

    /// Worker threads for inference: up to 4, leaving one core for capture and the UI.
    static var threadCount: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
    }
}
