import AVFoundation

/// Streaming mono sample-rate converter (captured audio, typically 48 kHz, to the 16 kHz
/// whisper expects). Wraps `AVAudioConverter`, which low-pass filters before decimating, and
/// keeps its filter state between calls so consecutive blocks join without clicks.
///
/// Not thread-safe: `WhisperTranscriber` uses one instance from its serial queue only.
final class AudioResampler {
    let inputRate: Double
    let outputRate: Double

    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    /// Nil when either rate is not positive or Core Audio rejects the pair.
    init?(inputRate: Double, outputRate: Double) {
        guard inputRate > 0, outputRate > 0,
              let input = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.inputRate = inputRate
        self.outputRate = outputRate
        inputFormat = input
        outputFormat = output
        self.converter = converter
    }

    /// Converts one block. The output length tracks `samples.count * outputRate / inputRate`
    /// over a stream of blocks; the first call returns slightly less (filter latency).
    func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        if inputRate == outputRate { return samples }
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let inputChannel = input.floatChannelData?[0] else { return [] }
        samples.withUnsafeBufferPointer { inputChannel.update(from: $0.baseAddress!, count: samples.count) }
        input.frameLength = AVAudioFrameCount(samples.count)

        let capacity = AVAudioFrameCount((Double(samples.count) * outputRate / inputRate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        // Hand the block over once, then report "no more for now" (not end of stream) so the
        // converter keeps its state for the next block.
        nonisolated(unsafe) var supplied = false
        let status = converter.convert(to: output, error: nil) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
