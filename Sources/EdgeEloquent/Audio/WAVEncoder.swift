//
//  WAVEncoder.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Multimodal Speech Intelligence.
//  Encodes PCM audio buffers into standard RIFF 44-byte WAV containers for Google AI Edge LiteRT-LM.
//

import Foundation

/// High-performance, allocation-conscious RIFF WAV encoder conforming to
/// Google AI Edge LiteRT-LM acoustic specifications (16 kHz, 16-bit Mono Linear PCM, Little-Endian).
public enum WAVEncoder {
    /// Canonical size of a standard PCM RIFF WAV header in bytes.
    public static let headerSize: Int = 44

    /// Validation result returned when inspecting a WAV container.
    public struct ValidationResult: Sendable, Equatable {
        public let isValid: Bool
        public let sampleRate: UInt32?
        public let channels: UInt16?
        public let bitsPerSample: UInt16?
        public let dataByteSize: UInt32?
        public let errorMessage: String?

        public init(
            isValid: Bool,
            sampleRate: UInt32? = nil,
            channels: UInt16? = nil,
            bitsPerSample: UInt16? = nil,
            dataByteSize: UInt32? = nil,
            errorMessage: String? = nil
        ) {
            self.isValid = isValid
            self.sampleRate = sampleRate
            self.channels = channels
            self.bitsPerSample = bitsPerSample
            self.dataByteSize = dataByteSize
            self.errorMessage = errorMessage
        }
    }

    // MARK: - Float32 to RIFF WAV Encoding

    /// Encodes normalized Float32 audio samples [-1.0, 1.0] into a standard 44-byte RIFF WAV file.
    ///
    /// - Parameters:
    ///   - samples: Array of Float32 audio samples in the range [-1.0, 1.0].
    ///   - sampleRate: Target acoustic sampling rate in Hz (default: 16,000 Hz).
    /// - Returns: Complete RIFF WAV formatted `Data` ready for LiteRT-LM ingestion.
    public static func encode(samples: [Float], sampleRate: Int = 16000) -> Data {
        samples.withUnsafeBufferPointer { buffer in
            encode(sampleBuffer: buffer, sampleRate: sampleRate)
        }
    }

    /// Encodes a raw buffer pointer of Float32 samples into a RIFF WAV container without intermediate array copies.
    ///
    /// - Parameters:
    ///   - sampleBuffer: Unsafe buffer pointer containing Float32 samples.
    ///   - sampleRate: Sampling frequency in Hz (default: 16,000 Hz).
    /// - Returns: Encoded RIFF WAV `Data`.
    public static func encode(sampleBuffer: UnsafeBufferPointer<Float>, sampleRate: Int = 16000) -> Data {
        let sampleCount = sampleBuffer.count
        let channels: Int = 1
        let bitsPerSample: Int = 16
        let bytesPerSample = bitsPerSample / 8
        let dataSize = sampleCount * channels * bytesPerSample

        var data = Data(capacity: headerSize + dataSize)

        // Write 44-byte RIFF header
        let header = createWAVHeader(
            dataSize: dataSize,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )
        data.append(header)

        // Fast quantization of Float32 to Int16 Little-Endian
        guard let baseAddress = sampleBuffer.baseAddress else {
            return data
        }

        // Allocate Int16 temporary buffer and pack directly
        var pcm16Samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let sample = baseAddress[i]
            pcm16Samples[i] = floatToInt16(sample: sample).littleEndian
        }

        pcm16Samples.withUnsafeBytes { rawBytes in
            data.append(contentsOf: rawBytes)
        }

        return data
    }

    // MARK: - PCM16 Data Wrapping

    /// Wraps pre-quantized 16-bit Signed Linear PCM byte data into a valid RIFF WAV container.
    ///
    /// - Parameters:
    ///   - pcm16Data: Raw Little-Endian 16-bit signed integer PCM data.
    ///   - sampleRate: Sampling rate in Hz (default: 16,000 Hz).
    ///   - channels: Number of audio channels (default: 1).
    /// - Returns: Complete RIFF WAV `Data` container.
    public static func encode(pcm16Data: Data, sampleRate: Int = 16000, channels: Int = 1) -> Data {
        let dataSize = pcm16Data.count
        let header = createWAVHeader(
            dataSize: dataSize,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: 16
        )
        var data = Data(capacity: headerSize + dataSize)
        data.append(header)
        data.append(pcm16Data)
        return data
    }

    // MARK: - Header Construction

    /// Generates a standard 44-byte canonical RIFF WAV header for Linear PCM audio.
    ///
    /// Header layout (44 bytes total):
    /// - [0..3]   "RIFF" marker (ASCII, Big-Endian)
    /// - [4..7]   ChunkSize = 36 + dataSize (UInt32, Little-Endian)
    /// - [8..11]  "WAVE" marker (ASCII, Big-Endian)
    /// - [12..15] "fmt " chunk marker (ASCII, Big-Endian)
    /// - [16..19] Subchunk1Size = 16 for PCM (UInt32, Little-Endian)
    /// - [20..21] AudioFormat = 1 for PCM (UInt16, Little-Endian)
    /// - [22..23] NumChannels (UInt16, Little-Endian)
    /// - [24..27] SampleRate (UInt32, Little-Endian)
    /// - [28..31] ByteRate = SampleRate * NumChannels * BitsPerSample / 8 (UInt32, Little-Endian)
    /// - [32..33] BlockAlign = NumChannels * BitsPerSample / 8 (UInt16, Little-Endian)
    /// - [34..35] BitsPerSample (UInt16, Little-Endian)
    /// - [36..39] "data" chunk marker (ASCII, Big-Endian)
    /// - [40..43] Subchunk2Size = dataSize (UInt32, Little-Endian)
    ///
    /// - Parameters:
    ///   - dataSize: Byte count of the raw PCM audio payload (Subchunk2Size).
    ///   - sampleRate: Audio sampling frequency in Hz (e.g. 16,000).
    ///   - channels: Number of channels (1 for Mono).
    ///   - bitsPerSample: Bit resolution (16 for 16-bit PCM).
    /// - Returns: 44-byte `Data` representing the RIFF WAV header.
    public static func createWAVHeader(
        dataSize: Int,
        sampleRate: Int = 16000,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data {
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let fileSize = 36 + dataSize

        var header = Data(capacity: headerSize)

        // 1. "RIFF" chunk descriptor
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        var chunkSizeLE = UInt32(fileSize).littleEndian
        header.append(Data(bytes: &chunkSizeLE, count: 4))
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // 2. "fmt " sub-chunk
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        var subchunk1SizeLE = UInt32(16).littleEndian // 16 for Linear PCM
        header.append(Data(bytes: &subchunk1SizeLE, count: 4))
        var audioFormatLE = UInt16(1).littleEndian // 1 = Linear PCM
        header.append(Data(bytes: &audioFormatLE, count: 2))
        var channelsLE = UInt16(channels).littleEndian
        header.append(Data(bytes: &channelsLE, count: 2))
        var sampleRateLE = UInt32(sampleRate).littleEndian
        header.append(Data(bytes: &sampleRateLE, count: 4))
        var byteRateLE = UInt32(byteRate).littleEndian
        header.append(Data(bytes: &byteRateLE, count: 4))
        var blockAlignLE = UInt16(blockAlign).littleEndian
        header.append(Data(bytes: &blockAlignLE, count: 2))
        var bitsPerSampleLE = UInt16(bitsPerSample).littleEndian
        header.append(Data(bytes: &bitsPerSampleLE, count: 2))

        // 3. "data" sub-chunk
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        var dataSizeLE = UInt32(dataSize).littleEndian
        header.append(Data(bytes: &dataSizeLE, count: 4))

        return header
    }

    // MARK: - Clamping & Quantization

    /// Quantizes a single normalized Float32 sample to signed 16-bit integer with strict clamping.
    ///
    /// Prevents integer overflow / wrapping artifacts on loud acoustic spikes.
    ///
    /// - Parameter sample: Normalized Float32 sample [-1.0, 1.0].
    /// - Returns: Clamped Int16 signed value [-32768, 32767].
    @inline(__always)
    public static func floatToInt16(sample: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, sample))
        if clamped >= 1.0 {
            return 32767
        } else if clamped <= -1.0 {
            return -32767
        } else {
            return Int16(clamped * 32767.0)
        }
    }

    // MARK: - Header Validation

    /// Validates an incoming Data buffer to verify that it begins with a valid canonical 44-byte RIFF WAV header.
    ///
    /// - Parameter data: In-memory byte buffer.
    /// - Returns: A `ValidationResult` detailing whether the buffer is a valid WAV container and its audio properties.
    public static func validateWAVHeader(_ data: Data) -> ValidationResult {
        guard data.count >= headerSize else {
            return ValidationResult(isValid: false, errorMessage: "Data size (\(data.count) bytes) is less than required 44-byte RIFF header.")
        }

        // 1. Verify "RIFF" marker (bytes 0-3)
        let riffMarker = data.subdata(in: 0..<4)
        guard riffMarker == Data([0x52, 0x49, 0x46, 0x46]) else {
            return ValidationResult(isValid: false, errorMessage: "Missing 'RIFF' magic bytes at offset 0.")
        }

        // 2. Read chunkSize (bytes 4-7)
        let chunkSize = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        let expectedFileSize = UInt32(data.count - 8)
        guard chunkSize == expectedFileSize else {
            return ValidationResult(
                isValid: false,
                errorMessage: "ChunkSize mismatch: header declares \(chunkSize), actual file size - 8 is \(expectedFileSize)."
            )
        }

        // 3. Verify "WAVE" marker (bytes 8-11)
        let waveMarker = data.subdata(in: 8..<12)
        guard waveMarker == Data([0x57, 0x41, 0x56, 0x45]) else {
            return ValidationResult(isValid: false, errorMessage: "Missing 'WAVE' format marker at offset 8.")
        }

        // 4. Verify "fmt " marker (bytes 12-15)
        let fmtMarker = data.subdata(in: 12..<16)
        guard fmtMarker == Data([0x66, 0x6D, 0x74, 0x20]) else {
            return ValidationResult(isValid: false, errorMessage: "Missing 'fmt ' chunk marker at offset 12.")
        }

        // 5. Verify Subchunk1Size = 16 (bytes 16-19)
        let subchunk1Size = data.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self) }
        guard subchunk1Size == 16 else {
            return ValidationResult(isValid: false, errorMessage: "Expected Subchunk1Size 16 for PCM, received \(subchunk1Size).")
        }

        // 6. AudioFormat = 1 (PCM) (bytes 20-21)
        let audioFormat = data.subdata(in: 20..<22).withUnsafeBytes { $0.load(as: UInt16.self) }
        guard audioFormat == 1 else {
            return ValidationResult(isValid: false, errorMessage: "Non-PCM format (\(audioFormat)) detected.")
        }

        // 7. Channels (bytes 22-23)
        let channels = data.subdata(in: 22..<24).withUnsafeBytes { $0.load(as: UInt16.self) }

        // 8. SampleRate (bytes 24-27)
        let sampleRate = data.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }

        // 9. ByteRate (bytes 28-31)
        let byteRate = data.subdata(in: 28..<32).withUnsafeBytes { $0.load(as: UInt32.self) }

        // 10. BlockAlign (bytes 32-33)
        let blockAlign = data.subdata(in: 32..<34).withUnsafeBytes { $0.load(as: UInt16.self) }

        // 11. BitsPerSample (bytes 34-35)
        let bitsPerSample = data.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self) }

        // Verify mathematical consistency
        let expectedBlockAlign = channels * (bitsPerSample / 8)
        guard blockAlign == expectedBlockAlign else {
            return ValidationResult(isValid: false, errorMessage: "Invalid BlockAlign: got \(blockAlign), expected \(expectedBlockAlign).")
        }

        let expectedByteRate = sampleRate * UInt32(expectedBlockAlign)
        guard byteRate == expectedByteRate else {
            return ValidationResult(isValid: false, errorMessage: "Invalid ByteRate: got \(byteRate), expected \(expectedByteRate).")
        }

        // 12. "data" marker (bytes 36-39)
        let dataMarker = data.subdata(in: 36..<40)
        guard dataMarker == Data([0x64, 0x61, 0x74, 0x61]) else {
            return ValidationResult(isValid: false, errorMessage: "Missing 'data' subchunk marker at offset 36.")
        }

        // 13. Subchunk2Size (bytes 40-43)
        let subchunk2Size = data.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        let expectedDataSize = UInt32(data.count - 44)
        guard subchunk2Size == expectedDataSize else {
            return ValidationResult(
                isValid: false,
                errorMessage: "Subchunk2Size mismatch: declared \(subchunk2Size), actual PCM data size is \(expectedDataSize)."
            )
        }

        return ValidationResult(
            isValid: true,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            dataByteSize: subchunk2Size,
            errorMessage: nil
        )
    }
}
