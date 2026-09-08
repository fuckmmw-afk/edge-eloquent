//
//  RecordingWaveformStore.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Multimodal Speech Intelligence.
//  Maintains real-time RMS power calculations, decibel normalization, and historical audio levels for SwiftUI visualizers.
//

import Foundation
#if canImport(Combine)
import Combine
#endif

/// Thread-safe store that calculates Root Mean Square (RMS) audio power, converts to decibels (dBFS),
/// and manages normalized audio levels for real-time waveform visualization in SwiftUI.
public final class RecordingWaveformStore: @unchecked Sendable {
    // MARK: - Configuration Constants

    /// Minimum threshold in decibels representing near-total silence.
    public static let minDecibels: Float = -60.0

    /// Maximum threshold in decibels representing full-scale acoustic saturation.
    public static let maxDecibels: Float = 0.0

    /// Minimum epsilon to prevent log10(0) evaluation.
    private static let rmsEpsilon: Float = 1e-5

    // MARK: - State Properties

    private let lock = NSLock()

    /// Maximum number of historical waveform bars retained for visual display.
    public let maxHistoryCount: Int

    /// Decay factor per frame for smooth peak level falloff [0.0 ... 1.0].
    public let peakDecayFactor: Float

    // Private synchronized storage backing variables
    private var _powerLevels: [Float]
    private var _latestPowerLevel: Float = 0.0
    private var _latestRMS: Float = 0.0
    private var _latestDecibels: Float = minDecibels
    private var _peakPowerLevel: Float = 0.0

    /// Current rolling history of normalized audio power levels in range [0.0, 1.0].
    public var powerLevels: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return _powerLevels
    }

    /// Most recently calculated normalized power level [0.0, 1.0].
    public var latestPowerLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return _latestPowerLevel
    }

    /// Most recently calculated raw RMS amplitude [0.0, 1.0].
    public var latestRMS: Float {
        lock.lock()
        defer { lock.unlock() }
        return _latestRMS
    }

    /// Most recently calculated decibel level [-60 dBFS, 0 dBFS].
    public var latestDecibels: Float {
        lock.lock()
        defer { lock.unlock() }
        return _latestDecibels
    }

    /// Peak power level with exponential decay for smooth UI animation.
    public var peakPowerLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return _peakPowerLevel
    }

    /// Callback closure invoked whenever a new power level frame is processed.
    public var onPowerLevelUpdated: (@Sendable (Float, [Float]) -> Void)?

    // MARK: - Initialization

    /// Initializes a waveform store with specified history capacity and decay dynamics.
    ///
    /// - Parameters:
    ///   - maxHistoryCount: Number of vertical waveform bars retained (default: 40).
    ///   - peakDecayFactor: Multiplier for peak power decay (default: 0.92).
    public init(maxHistoryCount: Int = 40, peakDecayFactor: Float = 0.92) {
        let count = max(1, maxHistoryCount)
        self.maxHistoryCount = count
        self.peakDecayFactor = min(1.0, max(0.0, peakDecayFactor))
        self._powerLevels = [Float](repeating: 0.0, count: count)
    }

    // MARK: - Audio Processing & Calculations

    /// Computes RMS energy from an array of Float32 audio samples, updates internal metrics,
    /// and pushes the normalized level into the rolling history.
    ///
    /// - Parameter samples: Array of Float32 PCM samples in range [-1.0, 1.0].
    /// - Returns: Newly computed normalized power level in range [0.0, 1.0].
    @discardableResult
    public func process(samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { buffer in
            process(sampleBuffer: buffer)
        }
    }

    /// Computes RMS energy directly from an unsafe buffer pointer to minimize heap churn.
    ///
    /// - Parameter sampleBuffer: Unsafe buffer pointer containing Float32 samples.
    /// - Returns: Newly computed normalized power level in range [0.0, 1.0].
    @discardableResult
    public func process(sampleBuffer: UnsafeBufferPointer<Float>) -> Float {
        guard let baseAddress = sampleBuffer.baseAddress, sampleBuffer.count > 0 else {
            return updateLevels(rms: 0.0, decibels: Self.minDecibels, normalized: 0.0)
        }

        let count = sampleBuffer.count
        var sumSquares: Float = 0.0

        for i in 0..<count {
            let sample = baseAddress[i]
            sumSquares += sample * sample
        }

        let meanSquare = sumSquares / Float(count)
        let rms = sqrt(meanSquare)
        let decibels = Self.calculateDecibels(fromRMS: rms)
        let normalized = Self.normalizeDecibels(decibels)

        return updateLevels(rms: rms, decibels: decibels, normalized: normalized)
    }

    /// Resets all power levels and historical waveform bars to silent baseline.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        self._powerLevels = [Float](repeating: 0.0, count: maxHistoryCount)
        self._latestPowerLevel = 0.0
        self._latestRMS = 0.0
        self._latestDecibels = Self.minDecibels
        self._peakPowerLevel = 0.0
    }

    // MARK: - Mathematical Helpers

    /// Computes decibels relative to full scale (dBFS) from an RMS amplitude value.
    ///
    /// Formula: `dBFS = 20 * log10(max(rms, 1e-5))`
    ///
    /// - Parameter rms: Root Mean Square amplitude in range [0.0, 1.0].
    /// - Returns: Decibels in range [-100.0 dBFS, 0.0 dBFS].
    @inline(__always)
    public static func calculateDecibels(fromRMS rms: Float) -> Float {
        let safeRMS = max(rms, rmsEpsilon)
        return 20.0 * log10(safeRMS)
    }

    /// Linearly normalizes a decibel value into a unit range [0.0, 1.0] for UI bar rendering.
    ///
    /// Values below `minDecibels` (-60 dB) map to 0.0, and values above `maxDecibels` (0 dB) map to 1.0.
    ///
    /// - Parameters:
    ///   - decibels: Decibel level.
    ///   - minDb: Minimum cutoff (default: -60 dB).
    ///   - maxDb: Maximum full-scale ceiling (default: 0 dB).
    /// - Returns: Normalized amplitude in range [0.0, 1.0].
    @inline(__always)
    public static func normalizeDecibels(_ decibels: Float, minDb: Float = minDecibels, maxDb: Float = maxDecibels) -> Float {
        if decibels <= minDb {
            return 0.0
        } else if decibels >= maxDb {
            return 1.0
        } else {
            return (decibels - minDb) / (maxDb - minDb)
        }
    }

    // MARK: - Private State Updates

    private func updateLevels(rms: Float, decibels: Float, normalized: Float) -> Float {
        lock.lock()
        let levelsSnapshot: [Float]
        let currentNormalized = normalized
        let callback = self.onPowerLevelUpdated

        self._latestRMS = rms
        self._latestDecibels = decibels
        self._latestPowerLevel = normalized

        // Update peak decay
        if normalized >= self._peakPowerLevel {
            self._peakPowerLevel = normalized
        } else {
            self._peakPowerLevel = max(0.0, self._peakPowerLevel * peakDecayFactor)
        }

        // Shift rolling history window
        if self._powerLevels.count >= maxHistoryCount {
            self._powerLevels.removeFirst()
        }
        self._powerLevels.append(normalized)
        levelsSnapshot = self._powerLevels

        lock.unlock()

        callback?(currentNormalized, levelsSnapshot)
        return currentNormalized
    }
}
