import AudioToolbox
import Testing
@testable import NotchPilotCore

private func asbd(formatID: AudioFormatID = kAudioFormatLinearPCM,
                  flags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                  bits: UInt32 = 32, sampleRate: Double = 48_000, channels: UInt32 = 2) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: formatID, mFormatFlags: flags,
                                mBytesPerPacket: bits / 8, mFramesPerPacket: 1, mBytesPerFrame: bits / 8,
                                mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
}

/// Runs `PCMConverter.interleave` over `source` and returns `frames * outputChannels` samples.
private func interleave(_ source: [Float], channels: Int, interleaved: Bool, stride: Int = 0,
                        frames: Int, outputChannels: Int) -> [Float] {
    var out = [Float](repeating: .nan, count: frames * outputChannels)
    source.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            PCMConverter.interleave(source: src.baseAddress!, sourceChannels: channels,
                                    sourceIsInterleaved: interleaved, sourceChannelStride: stride,
                                    frames: frames, into: dst.baseAddress!, outputChannels: outputChannels)
        }
    }
    return out
}

@Suite("PCMConverter.validate")
struct PCMConverterValidateTests {

    @Test("accepts 48 kHz stereo Float32")
    func acceptsFloat32Stereo() {
        #expect(PCMConverter.validate(asbd(), expectedSampleRate: 48_000) == nil)
    }

    @Test("rejects non-linear-PCM formats")
    func rejectsNonLinearPCM() {
        #expect(PCMConverter.validate(asbd(formatID: kAudioFormatMPEG4AAC), expectedSampleRate: 48_000) == .notLinearPCM)
    }

    @Test("rejects 16-bit integer samples")
    func rejectsInt16() {
        let int16 = asbd(flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, bits: 16)
        #expect(PCMConverter.validate(int16, expectedSampleRate: 48_000) == .notFloat32)
    }

    @Test("rejects a sample rate that would need resampling")
    func rejectsSampleRateMismatch() {
        #expect(PCMConverter.validate(asbd(sampleRate: 44_100), expectedSampleRate: 48_000) == .sampleRateMismatch)
    }

    @Test("rejects more channels than the converter can hold")
    func rejectsTooManyChannels() {
        let channels = UInt32(PCMConverter.maxInputChannels + 1)
        #expect(PCMConverter.validate(asbd(channels: channels), expectedSampleRate: 48_000) == .tooManyChannels)
    }
}

@Suite("PCMConverter.interleave")
struct PCMConverterInterleaveTests {

    @Test("planar stereo becomes interleaved stereo")
    func planarStereoToInterleaved() {
        // Two planes of 3 frames, plane stride 4 (one unused slot per plane).
        let planar: [Float] = [1, 2, 3, .nan, 10, 20, 30, .nan]
        let out = interleave(planar, channels: 2, interleaved: false, stride: 4, frames: 3, outputChannels: 2)
        #expect(out == [1, 10, 2, 20, 3, 30])
    }

    @Test("an interleaved stereo source passes through unchanged")
    func interleavedPassthrough() {
        let source: [Float] = [1, -1, 2, -2, 3, -3]
        #expect(interleave(source, channels: 2, interleaved: true, frames: 3, outputChannels: 2) == source)
    }

    @Test("a mono source is duplicated to both output channels")
    func monoToStereoDuplicates() {
        let out = interleave([0.25, 0.5, 0.75], channels: 1, interleaved: true, frames: 3, outputChannels: 2)
        #expect(out == [0.25, 0.25, 0.5, 0.5, 0.75, 0.75])
    }

    @Test("a mono output averages the first two source channels")
    func stereoToMonoAverages() {
        let out = interleave([1, 0, 0.5, -0.5, 1, 1], channels: 2, interleaved: true, frames: 3, outputChannels: 1)
        #expect(out == [0.5, 0, 1])
    }

    @Test("sources with more than two channels map their first two channels")
    func extraChannelsIgnored() {
        let source: [Float] = [1, 2, 9, 9, 3, 4, 9, 9]   // 4-channel interleaved, 2 frames
        #expect(interleave(source, channels: 4, interleaved: true, frames: 2, outputChannels: 2) == [1, 2, 3, 4])
    }
}
