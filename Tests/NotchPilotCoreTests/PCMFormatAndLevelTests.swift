import Testing
@testable import NotchPilotCore

@Suite("PCMFormat")
struct PCMFormatTests {

    @Test("describes 48 kHz stereo")
    func stereo48k() {
        #expect(PCMFormat(sampleRate: 48_000, channelCount: 2).description == "48 kHz · Stereo · Float32")
    }

    @Test("describes mono")
    func mono() {
        #expect(PCMFormat(sampleRate: 48_000, channelCount: 1).description == "48 kHz · Mono · Float32")
    }

    @Test("describes a fractional kHz rate with one decimal")
    func fractionalRate() {
        #expect(PCMFormat(sampleRate: 44_100, channelCount: 2).description == "44.1 kHz · Stereo · Float32")
    }

    @Test("describes more than two channels by count")
    func multichannel() {
        #expect(PCMFormat(sampleRate: 48_000, channelCount: 6).description == "48 kHz · 6 ch · Float32")
    }
}

@Suite("LevelSnapshot")
struct LevelSnapshotTests {

    @Test("silence is floored at -60 dB and normalizes to 0", arguments: [Float(0), 0.0005])
    func silenceFloors(rms: Float) {
        let level = LevelSnapshot(rms: rms)
        #expect(level.rmsDecibels == -60)
        #expect(level.normalizedLevel == 0)
    }

    @Test("full scale is 0 dB and normalizes to 1")
    func fullScale() {
        let level = LevelSnapshot(rms: 1)
        #expect(level.rmsDecibels == 0)
        #expect(level.normalizedLevel == 1)
    }

    @Test("0.1 RMS is -20 dB, two thirds of the meter")
    func midLevel() {
        let level = LevelSnapshot(rms: 0.1)
        #expect(abs(level.rmsDecibels - -20) < 0.001)
        #expect(abs(level.normalizedLevel - 2.0 / 3.0) < 0.001)
    }

    @Test("normalized level stays within 0...1 for levels up to full scale",
          arguments: stride(from: Float(0), through: 1, by: 0.05).map { $0 })
    func normalizedWithinBounds(rms: Float) {
        let normalized = LevelSnapshot(rms: rms).normalizedLevel
        #expect(normalized >= 0 && normalized <= 1)
    }
}
