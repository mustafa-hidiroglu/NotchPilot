import AudioToolbox
import CoreMedia

/// The stable PCM format NotchPilot publishes to the C++ ring and downstream consumers:
/// 32-bit float, native endian, interleaved, `channelCount` channels at `sampleRate`.
public struct PCMFormat: Sendable, Equatable, CustomStringConvertible {
    public var sampleRate: Double
    public var channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var description: String {
        let rate = sampleRate.truncatingRemainder(dividingBy: 1000) == 0
            ? "\(Int(sampleRate / 1000)) kHz" : String(format: "%.1f kHz", sampleRate / 1000)
        let layout = switch channelCount { case 1: "Mono"; case 2: "Stereo"; default: "\(channelCount) ch" }
        return "\(rate) · \(layout) · Float32"
    }
}

/// Converts ScreenCaptureKit audio sample buffers into interleaved Float32 frames in the
/// published `PCMFormat`, using only memory preallocated in `init`.
///
/// Thread-safety: not thread-safe. Owned by `AudioStreamSink` and used exclusively on its
/// serial sample-handler queue.
///
/// Buffer lifetime: audio is copied out of the CMSampleBuffer with
/// `CMSampleBufferCopyPCMDataIntoAudioBufferList` into converter-owned scratch memory, so no
/// pointer into a framework-owned buffer survives the callback that delivered it.
final class PCMConverter {

    /// Why an input buffer was discarded. Raw values travel through the C++ ring as the
    /// "last reject reason" (0 is reserved for "none").
    enum Rejection: UInt32, Sendable, CustomStringConvertible {
        case notLinearPCM = 1
        case notFloat32 = 2
        case sampleRateMismatch = 3
        case tooManyChannels = 4
        case bufferTooLarge = 5
        case copyFailed = 6
        case missingFormat = 7

        /// Structural: every following buffer will be rejected too, so capture should stop.
        /// The rest are per-buffer problems that are counted and skipped.
        var isFatal: Bool {
            switch self {
            case .notLinearPCM, .notFloat32, .sampleRateMismatch, .tooManyChannels: true
            case .bufferTooLarge, .copyFailed, .missingFormat: false
            }
        }

        var description: String {
            switch self {
            case .notLinearPCM: "not linear PCM"
            case .notFloat32: "not 32-bit float samples"
            case .sampleRateMismatch: "unexpected sample rate"
            case .tooManyChannels: "more than \(PCMConverter.maxInputChannels) channels"
            case .bufferTooLarge: "buffer larger than the configured maximum"
            case .copyFailed: "sample data could not be read"
            case .missingFormat: "no format description"
            }
        }
    }

    enum Outcome {
        /// `frames` interleaved frames are ready at `samples` until the next `convert` call.
        case converted(samples: UnsafePointer<Float>, frames: Int)
        case rejected(frames: Int, reason: Rejection)
        case empty
    }

    static let maxInputChannels = 8

    let format: PCMFormat
    let maxFrames: Int

    private let planar: UnsafeMutablePointer<Float>        // maxInputChannels * maxFrames
    private let interleaved: UnsafeMutablePointer<Float>   // channelCount * maxFrames
    private let bufferList: UnsafeMutableAudioBufferListPointer

    init(format: PCMFormat, maxFrames: Int) {
        // Bounds keep every UInt32/Int32 byte and frame count below overflow.
        precondition((1...Self.maxInputChannels).contains(format.channelCount))
        precondition((1...(1 << 16)).contains(maxFrames))
        self.format = format
        self.maxFrames = maxFrames
        planar = .allocate(capacity: Self.maxInputChannels * maxFrames)
        planar.initialize(repeating: 0, count: Self.maxInputChannels * maxFrames)
        interleaved = .allocate(capacity: format.channelCount * maxFrames)
        interleaved.initialize(repeating: 0, count: format.channelCount * maxFrames)
        bufferList = AudioBufferList.allocate(maximumBuffers: Self.maxInputChannels)
    }

    deinit {
        planar.deallocate()
        interleaved.deallocate()
        free(bufferList.unsafeMutablePointer)
    }

    /// Capture-callback path: no allocation, locking or logging in NotchPilot's code. (The
    /// CoreMedia copy is framework code and may lock internally; the callback runs on a
    /// dispatch queue, not a CoreAudio I/O thread.)
    func convert(_ sampleBuffer: CMSampleBuffer) -> Outcome {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return .empty }

        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return .rejected(frames: frames, reason: .missingFormat)
        }
        if let rejection = Self.validate(asbd, expectedSampleRate: format.sampleRate) {
            return .rejected(frames: frames, reason: rejection)
        }
        guard frames <= maxFrames else { return .rejected(frames: frames, reason: .bufferTooLarge) }

        let channels = Int(asbd.mChannelsPerFrame)
        let isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let byteCount = UInt32(frames * MemoryLayout<Float>.size)

        // Point the preallocated AudioBufferList at our scratch memory in the source layout.
        if isInterleaved {
            bufferList.count = 1
            bufferList[0] = AudioBuffer(mNumberChannels: UInt32(channels),
                                        mDataByteSize: byteCount * UInt32(channels),
                                        mData: UnsafeMutableRawPointer(planar))
        } else {
            bufferList.count = channels
            for channel in 0..<channels {
                bufferList[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount,
                                                  mData: UnsafeMutableRawPointer(planar + channel * maxFrames))
            }
        }

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: bufferList.unsafeMutablePointer)
        guard status == noErr else { return .rejected(frames: frames, reason: .copyFailed) }

        Self.interleave(source: planar, sourceChannels: channels, sourceIsInterleaved: isInterleaved,
                        sourceChannelStride: maxFrames, frames: frames,
                        into: interleaved, outputChannels: format.channelCount)
        return .converted(samples: UnsafePointer(interleaved), frames: frames)
    }

    /// Checks that a stream description can be converted without resampling.
    static func validate(_ asbd: AudioStreamBasicDescription, expectedSampleRate: Double) -> Rejection? {
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return .notLinearPCM }
        guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return .notFloat32 }
        guard asbd.mChannelsPerFrame >= 1, Int(asbd.mChannelsPerFrame) <= maxInputChannels else { return .tooManyChannels }
        // Packed samples only: 4 bytes per frame per buffer (planar) or per channel (interleaved).
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let expectedBytesPerFrame = UInt32(MemoryLayout<Float>.size) * (interleaved ? asbd.mChannelsPerFrame : 1)
        guard asbd.mBytesPerFrame == expectedBytesPerFrame else { return .notFloat32 }
        guard abs(asbd.mSampleRate - expectedSampleRate) < 0.5 else { return .sampleRateMismatch }
        return nil
    }

    /// Channel mapping into the published layout. Mono sources are duplicated to every
    /// output channel; extra source channels beyond the output count are ignored
    /// (ScreenCaptureKit delivers the requested channel count, so this is a guard, not a
    /// mixer); a mono output averages the first two source channels.
    ///
    /// - Parameters:
    ///   - sourceChannelStride: distance in samples between channel planes when the source is
    ///     planar; ignored for interleaved sources.
    static func interleave(source: UnsafePointer<Float>, sourceChannels: Int, sourceIsInterleaved: Bool,
                           sourceChannelStride: Int, frames: Int,
                           into destination: UnsafeMutablePointer<Float>, outputChannels: Int) {
        @inline(__always) func sample(_ frame: Int, _ channel: Int) -> Float {
            sourceIsInterleaved ? source[frame * sourceChannels + channel]
                                : source[channel * sourceChannelStride + frame]
        }

        if outputChannels == 1 && sourceChannels >= 2 {
            for frame in 0..<frames {
                destination[frame] = 0.5 * (sample(frame, 0) + sample(frame, 1))
            }
            return
        }
        for frame in 0..<frames {
            let base = frame * outputChannels
            for channel in 0..<outputChannels {
                destination[base + channel] = sample(frame, min(channel, sourceChannels - 1))
            }
        }
    }
}
