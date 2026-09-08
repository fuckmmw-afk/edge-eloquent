//
//  AudioTests.swift
//  EdgeEloquentTests
//
//  Created for Edge Eloquent: On-Device Multimodal Speech Intelligence.
//  Unit tests validating WAVEncoder RIFF headers, PCM quantization, RMS audio math, and sliding window chunking.
//

import XCTest
@testable import EdgeEloquent

final class AudioTests: XCTestCase {

    // MARK: - WAVEncoder RIFF Header & Field Tests

    func testWAVHeaderCanonicalMagicBytes() {
        let emptySamples: [Float] = []
        let wavData = WAVEncoder.encode(samples: emptySamples, sampleRate: 16000)

        XCTAssertEqual(wavData.count, 44, "Empty audio WAV file must be exactly 44 bytes (header only)")

        // 1. Bytes 0-3: "RIFF" (0x52, 0x49, 0x46, 0x46)
        let riff = String(data: wavData.subdata(in: 0..<4), encoding: .ascii)
        XCTAssertEqual(riff, "RIFF")

        // 2. Bytes 8-11: "WAVE" (0x57, 0x41, 0x56, 0x45)
        let wave = String(data: wavData.subdata(in: 8..<12), encoding: .ascii)
        XCTAssertEqual(wave, "WAVE")

        // 3. Bytes 12-15: "fmt " (0x66, 0x6D, 0x74, 0x20)
        let fmt = String(data: wavData.subdata(in: 12..<16), encoding: .ascii)
        XCTAssertEqual(fmt, "fmt ")

        // 4. Bytes 36-39: "data" (0x64, 0x61, 0x74, 0x61)
        let dataMarker = String(data: wavData.subdata(in: 36..<40), encoding: .ascii)
        XCTAssertEqual(dataMarker, "data")
    }

    func testWAVHeaderLittleEndianFields() {
        let sampleCount = 100
        let samples = [Float](repeating: 0.1, count: sampleCount)
        let sampleRate: Int = 16000
        let wavData = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)

        // Subchunk1Size = 16 (UInt32 LE, bytes 16-19)
        let subchunk1Size = wavData.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(subchunk1Size, 16)

        // AudioFormat = 1 (UInt16 LE, bytes 20-21)
        let audioFormat = wavData.subdata(in: 20..<22).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(audioFormat, 1, "Audio format must be 1 (Linear PCM)")

        // NumChannels = 1 (UInt16 LE, bytes 22-23)
        let channels = wavData.subdata(in: 22..<24).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(channels, 1, "Channel count must be 1 (Mono)")

        // SampleRate = 16000 (UInt32 LE, bytes 24-27)
        let actualSampleRate = wavData.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(actualSampleRate, 16000)

        // ByteRate = 32000 (UInt32 LE, bytes 28-31) = 16000 * 1 * 2
        let byteRate = wavData.subdata(in: 28..<32).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(byteRate, 32000)

        // BlockAlign = 2 (UInt16 LE, bytes 32-33) = 1 * (16 / 8)
        let blockAlign = wavData.subdata(in: 32..<34).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(blockAlign, 2)

        // BitsPerSample = 16 (UInt16 LE, bytes 34-35)
        let bitsPerSample = wavData.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(bitsPerSample, 16)
    }

    func test15SecondWindowExactSizeCalculations() {
        // 15 seconds of 16 kHz mono audio = 240,000 samples
        let sampleRate = 16000
        let durationSeconds = 15.0
        let expectedSampleCount = Int(Double(sampleRate) * durationSeconds)
        XCTAssertEqual(expectedSampleCount, 240_000, "15s @ 16kHz must equal 240,000 samples")

        let expectedDataSize = expectedSampleCount * 2 // 16-bit = 2 bytes/sample
        XCTAssertEqual(expectedDataSize, 480_000, "15s of 16-bit audio must equal 480,000 bytes")

        let expectedChunkSize = 36 + expectedDataSize
        XCTAssertEqual(expectedChunkSize, 480_036)

        let expectedTotalFileSize = 44 + expectedDataSize
        XCTAssertEqual(expectedTotalFileSize, 480_044)

        // Generate synthetic 15-second audio buffer
        let dummySamples = [Float](repeating: 0.0, count: expectedSampleCount)
        let wavData = WAVEncoder.encode(samples: dummySamples, sampleRate: sampleRate)

        XCTAssertEqual(wavData.count, expectedTotalFileSize)

        // Verify ChunkSize field
        let chunkSize = wavData.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(chunkSize, UInt32(expectedChunkSize))

        // Verify Subchunk2Size field
        let subchunk2Size = wavData.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(subchunk2Size, UInt32(expectedDataSize))

        // Validate via header validator
        let validation = WAVEncoder.validateWAVHeader(wavData)
        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(validation.sampleRate, 16000)
        XCTAssertEqual(validation.channels, 1)
        XCTAssertEqual(validation.bitsPerSample, 16)
        XCTAssertEqual(validation.dataByteSize, 480_000)
        XCTAssertNil(validation.errorMessage)
    }

    // MARK: - Float32 to Int16 Clamping & Quantization Tests

    func testFloatToInt16ClampingAndQuantization() {
        // Zero point
        XCTAssertEqual(WAVEncoder.floatToInt16(sample: 0.0), 0)

        // Positive full-scale
        XCTAssertEqual(WAVEncoder.floatToInt16(sample: 1.0), 32767)

        // Negative full-scale
        XCTAssertEqual(WAVEncoder.floatToInt16(sample: -1.0), -32767)

        // Overshoot clamping (> 1.0)
        XCTAssertEqual(WAVEncoder.floatToInt16(sample: 1.5), 32767)
        XCTAssertEqual(WAVEncoder.floatToInt16(sample: 100.0), 32767)

        // Undershoot clamping (< -1.0)
        XCTAssertEqual(WAVEncoder.floatToInt16(sample: -1.5), -32767)
        XCTAssertEqual(WAVEncoder.floatToInt16(sample: -50.0), -32767)

        // Mid-scale value: 0.5 * 32767.0 = 16383.5 -> 16383
        let mid = WAVEncoder.floatToInt16(sample: 0.5)
        XCTAssertEqual(mid, 16383)

        // Negative mid-scale: -0.5 * 32767.0 = -16383.5 -> -16383
        let negMid = WAVEncoder.floatToInt16(sample: -0.5)
        XCTAssertEqual(negMid, -16383)
    }

    func testWAVEncoderPayloadIntegrity() {
        let testSamples: [Float] = [0.0, 1.0, -1.0, 0.5]
        let wavData = WAVEncoder.encode(samples: testSamples, sampleRate: 16000)

        XCTAssertEqual(wavData.count, 44 + 4 * 2)

        let payloadData = wavData.subdata(in: 44..<wavData.count)
        var parsedInt16: [Int16] = []
        payloadData.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Int16.self)
            parsedInt16 = Array(buffer)
        }

        XCTAssertEqual(parsedInt16.count, 4)
        XCTAssertEqual(parsedInt16[0], 0)
        XCTAssertEqual(parsedInt16[1], 32767)
        XCTAssertEqual(parsedInt16[2], -32767)
        XCTAssertEqual(parsedInt16[3], 16383)
    }

    // MARK: - WAV Header Validation Tests

    func testValidateWAVHeaderRejectsCorruptedBuffers() {
        // 1. Buffer too short
        let shortBuffer = Data([0x52, 0x49, 0x46, 0x46])
        let shortResult = WAVEncoder.validateWAVHeader(shortBuffer)
        XCTAssertFalse(shortResult.isValid)

        // 2. Corrupt RIFF marker
        var validWav = WAVEncoder.encode(samples: [0.1, 0.2], sampleRate: 16000)
        validWav[0] = 0x00 // Alter 'R' to 0x00
        let badRiffResult = WAVEncoder.validateWAVHeader(validWav)
        XCTAssertFalse(badRiffResult.isValid)
        XCTAssertTrue(badRiffResult.errorMessage?.contains("RIFF") == true)

        // 3. Corrupt WAVE marker
        var badWave = WAVEncoder.encode(samples: [0.1, 0.2], sampleRate: 16000)
        badWave[8] = 0x00
        let badWaveResult = WAVEncoder.validateWAVHeader(badWave)
        XCTAssertFalse(badWaveResult.isValid)
        XCTAssertTrue(badWaveResult.errorMessage?.contains("WAVE") == true)
    }

    // MARK: - RecordingWaveformStore RMS & Math Tests

    func testRecordingWaveformStoreSilence() {
        let store = RecordingWaveformStore(maxHistoryCount: 40)
        let silenceSamples = [Float](repeating: 0.0, count: 1600) // 100ms of silence

        let power = store.process(samples: silenceSamples)

        XCTAssertEqual(store.latestRMS, 0.0, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(store.latestDecibels, -60.0)
        XCTAssertEqual(power, 0.0, accuracy: 1e-6)
        XCTAssertEqual(store.latestPowerLevel, 0.0, accuracy: 1e-6)
    }

    func testRecordingWaveformStoreFullScaleSineAndSquare() {
        let store = RecordingWaveformStore(maxHistoryCount: 40)

        // Alternating +/- 1.0 (Square wave at Nyquist): RMS = sqrt(mean(1^2)) = 1.0
        var squareWave: [Float] = []
        for i in 0..<1000 {
            squareWave.append(i % 2 == 0 ? 1.0 : -1.0)
        }

        let power = store.process(samples: squareWave)

        XCTAssertEqual(store.latestRMS, 1.0, accuracy: 1e-4)
        XCTAssertEqual(store.latestDecibels, 0.0, accuracy: 1e-2)
        XCTAssertEqual(power, 1.0, accuracy: 1e-4)
        XCTAssertEqual(store.latestPowerLevel, 1.0, accuracy: 1e-4)
    }

    func testRecordingWaveformStoreDecibelCalculations() {
        // RMS = 1.0 -> 0 dBFS
        let dbFull = RecordingWaveformStore.calculateDecibels(fromRMS: 1.0)
        XCTAssertEqual(dbFull, 0.0, accuracy: 1e-4)

        // RMS = 0.5 -> 20 * log10(0.5) = -6.0206 dBFS
        let dbHalf = RecordingWaveformStore.calculateDecibels(fromRMS: 0.5)
        XCTAssertEqual(dbHalf, -6.0206, accuracy: 1e-3)

        // RMS = 0.1 -> -20 dBFS
        let dbTenth = RecordingWaveformStore.calculateDecibels(fromRMS: 0.1)
        XCTAssertEqual(dbTenth, -20.0, accuracy: 1e-3)

        // RMS = 0.0 -> clamped by epsilon to -100 dBFS
        let dbZero = RecordingWaveformStore.calculateDecibels(fromRMS: 0.0)
        XCTAssertEqual(dbZero, -100.0, accuracy: 1e-2)
    }

    func testRecordingWaveformStoreNormalization() {
        // -60 dB maps to 0.0
        XCTAssertEqual(RecordingWaveformStore.normalizeDecibels(-60.0), 0.0, accuracy: 1e-5)

        // -70 dB (below min) clamps to 0.0
        XCTAssertEqual(RecordingWaveformStore.normalizeDecibels(-70.0), 0.0, accuracy: 1e-5)

        // 0 dB maps to 1.0
        XCTAssertEqual(RecordingWaveformStore.normalizeDecibels(0.0), 1.0, accuracy: 1e-5)

        // +5 dB (above max) clamps to 1.0
        XCTAssertEqual(RecordingWaveformStore.normalizeDecibels(5.0), 1.0, accuracy: 1e-5)

        // -30 dB (midpoint between -60 and 0) maps to 0.5
        XCTAssertEqual(RecordingWaveformStore.normalizeDecibels(-30.0), 0.5, accuracy: 1e-5)
    }

    func testRecordingWaveformStoreHistoryCapacity() {
        let maxBars = 10
        let store = RecordingWaveformStore(maxHistoryCount: maxBars)

        // Feed 50 frames
        for i in 0..<50 {
            let sample: Float = Float(i % 10) / 10.0
            store.process(samples: [sample])
        }

        XCTAssertEqual(store.powerLevels.count, maxBars, "Power levels history must be capped at maxHistoryCount")
    }

    func testRecordingWaveformStorePeakDecay() {
        let store = RecordingWaveformStore(maxHistoryCount: 10, peakDecayFactor: 0.5)

        // 1. Peak event at 1.0
        store.process(samples: [1.0, -1.0])
        XCTAssertEqual(store.peakPowerLevel, 1.0, accuracy: 1e-4)

        // 2. Silence event: peak should decay by factor of 0.5
        store.process(samples: [0.0, 0.0])
        XCTAssertEqual(store.peakPowerLevel, 0.5, accuracy: 1e-4)

        // 3. Next silence event: peak decays to 0.25
        store.process(samples: [0.0, 0.0])
        XCTAssertEqual(store.peakPowerLevel, 0.25, accuracy: 1e-4)
    }

    // MARK: - Audio Windowing & Token Density Math Tests

    func testAudioDurationAndChunkingMath() {
        let sampleRate = 16000.0

        // Minimum duration gating: 0.5s = 8,000 samples
        let minSamples = 8_000
        let minDuration = Double(minSamples) / sampleRate
        XCTAssertEqual(minDuration, 0.5, accuracy: 1e-5)

        // Standard 15s window: 240,000 samples
        let window15Samples = 240_000
        let duration15 = Double(window15Samples) / sampleRate
        XCTAssertEqual(duration15, 15.0, accuracy: 1e-5)

        // Max 30s window: 480,000 samples
        let window30Samples = 480_000
        let duration30 = Double(window30Samples) / sampleRate
        XCTAssertEqual(duration30, 30.0, accuracy: 1e-5)

        // Token density estimates for 15s chunk (25 to 50 tokens/sec)
        let minExpectedTokens = Int(duration15 * 25.0)
        let maxExpectedTokens = Int(duration15 * 50.0)
        XCTAssertEqual(minExpectedTokens, 375)
        XCTAssertEqual(maxExpectedTokens, 750)
    }
}
