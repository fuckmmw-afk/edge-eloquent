//
//  UnifiedAudioCapture.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Multimodal Speech Intelligence.
//  Captures microphone audio via AVAudioEngine, resamples to 16kHz mono Float32,
//  implements VAD silence detection and 15s chunk windowing, and streams WAV-encoded audio chunks.
//

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(OSLog)
import OSLog
#endif

/// Represents an encoded audio segment produced by the capture pipeline for inference.
public struct AudioChunk: Sendable, Identifiable {
    public let id: UUID
    public let samples: [Float]
    public let wavData: Data
    public let sampleRate: Int
    public let durationSeconds: Double
    public let isFinal: Bool

    public init(
        id: UUID = UUID(),
        samples: [Float],
        wavData: Data,
        sampleRate: Int = 16000,
        durationSeconds: Double,
        isFinal: Bool = false
    ) {
        self.id = id
        self.samples = samples
        self.wavData = wavData
        self.sampleRate = sampleRate
        self.durationSeconds = durationSeconds
        self.isFinal = isFinal
    }
}

/// Errors occurring during audio capture and conversion.
public enum AudioCaptureError: LocalizedError, Sendable {
    case engineInitializationFailed
    case invalidInputFormat
    case converterCreationFailed
    case conversionFailed(String)
    case notRecording
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .engineInitializationFailed:
            return "Failed to initialize AVAudioEngine."
        case .invalidInputFormat:
            return "AVAudioEngine inputNode has an invalid audio format."
        case .converterCreationFailed:
            return "Failed to create AVAudioConverter for 16kHz mono resampling."
        case .conversionFailed(let reason):
            return "Audio conversion error: \(reason)"
        case .notRecording:
            return "Audio capture is not currently recording."
        case .permissionDenied:
            return "Microphone recording permission was denied."
        }
    }
}

/// Delegate protocol for receiving captured audio chunks and real-time power updates.
public protocol UnifiedAudioCaptureDelegate: AnyObject, Sendable {
    func audioCaptureDidEmitChunk(_ capture: UnifiedAudioCapture, chunk: AudioChunk)
    func audioCaptureDidUpdatePower(_ capture: UnifiedAudioCapture, power: Float, decibels: Float)
    func audioCaptureDidFail(_ capture: UnifiedAudioCapture, error: Error)
}

/// High-performance audio capture manager utilizing AVAudioEngine and AVAudioConverter.
/// Feeds resampled 16kHz mono PCM frames into an energy-gated chunker and WAVEncoder.
public final class UnifiedAudioCapture: @unchecked Sendable {
    // MARK: - Constants & Configuration

    /// Standard acoustic target sample rate conforming to Google AI Edge runtime.
    public static let targetSampleRate: Double = 16000.0

    /// Number of audio channels (1 = Mono).
    public static let targetChannelCount: AVAudioChannelCount = 1

    /// Samples per 15-second standard window (16,000 * 15 = 240,000).
    public static let samplesPer15Seconds: Int = 240_000

    /// Maximum duration of continuous audio before mandatory chunk slicing (seconds).
    public let maxSliceDuration: TimeInterval

    /// Minimum duration required to emit a valid chunk (seconds). Slices below this are discarded.
    public let minSliceDuration: TimeInterval

    /// Silence duration in seconds required to trigger an automatic end-of-utterance slice.
    public let silenceThresholdDuration: TimeInterval

    /// Decibel threshold below which audio is classified as silence (dBFS).
    public let silenceDecibelThreshold: Float

    // MARK: - Subsystems & State

    public let sessionCoordinator: AudioSessionCoordinator
    public let waveformStore: RecordingWaveformStore
    public weak var delegate: UnifiedAudioCaptureDelegate?

    #if canImport(AVFoundation)
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    #endif

    private let lock = NSLock()
    private var isRunning: Bool = false
    private var isPaused: Bool = false

    // Sample accumulation & VAD tracking
    private var accumulatedSamples: [Float] = []
    private var lastSpeechTimestamp: Date = Date()
    private var hasDetectedSpeechInCurrentSlice: Bool = false

    // AsyncStream Continuation
    private var chunkStreamContinuation: AsyncStream<AudioChunk>.Continuation?

    // MARK: - Initialization

    /// Initializes the unified audio capture pipeline.
    ///
    /// - Parameters:
    ///   - sessionCoordinator: Shared AudioSessionCoordinator instance.
    ///   - waveformStore: Store for real-time waveform level calculation.
    ///   - maxSliceDuration: Maximum slice duration before automatic window cut (default: 15.0s).
    ///   - minSliceDuration: Minimum slice duration required to emit chunk (default: 0.5s / 8,000 samples).
    ///   - silenceThresholdDuration: Continuous silence required to commit utterance (default: 1.2s).
    ///   - silenceDecibelThreshold: Threshold in dBFS below which audio is silent (default: -45.0 dBFS).
    public init(
        sessionCoordinator: AudioSessionCoordinator = AudioSessionCoordinator(),
        waveformStore: RecordingWaveformStore = RecordingWaveformStore(),
        maxSliceDuration: TimeInterval = 15.0,
        minSliceDuration: TimeInterval = 0.5,
        silenceThresholdDuration: TimeInterval = 1.2,
        silenceDecibelThreshold: Float = -45.0
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.waveformStore = waveformStore
        self.maxSliceDuration = maxSliceDuration
        self.minSliceDuration = minSliceDuration
        self.silenceThresholdDuration = silenceThresholdDuration
        self.silenceDecibelThreshold = silenceDecibelThreshold
        self.sessionCoordinator.delegate = self

        #if canImport(AVFoundation)
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannelCount,
            interleaved: false
        )
        #endif

        // Hook interruption notifications to gracefully pause and resume capture
        self.sessionCoordinator.onInterruptionBegan = { [weak self] in
            self?.pauseCapture()
        }
        self.sessionCoordinator.onInterruptionEnded = { [weak self] shouldResume in
            if shouldResume {
                try? self?.resumeCapture()
            }
        }
    }

    deinit {
        stopCaptureSync()
    }

    // MARK: - AsyncStream Interface

    /// AsyncStream yielding discrete, WAV-encoded audio chunks as they are emitted in real-time.
    public var chunkStream: AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            self.lock.lock()
            self.chunkStreamContinuation = continuation
            self.lock.unlock()

            continuation.onTermination = { @Sendable _ in
                // Stream cleanup if consumer terminates
            }
        }
    }

    // MARK: - Synchronous Lock Helpers

    private func checkIsRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    private func markRunning() {
        lock.lock()
        defer { lock.unlock() }
        self.isRunning = true
        self.isPaused = false
        self.accumulatedSamples.removeAll(keepingCapacity: true)
        self.lastSpeechTimestamp = Date()
        self.hasDetectedSpeechInCurrentSlice = false
    }

    private func prepareStopCapture() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return nil }
        isRunning = false
        isPaused = false
        let samples = accumulatedSamples
        accumulatedSamples.removeAll()
        return samples
    }

    private func finishContinuation() {
        lock.lock()
        defer { lock.unlock() }
        chunkStreamContinuation?.finish()
        chunkStreamContinuation = nil
    }

    // MARK: - Capture Lifecycle Controls

    /// Starts audio capture by configuring the session, installing the engine tap, and launching AVAudioEngine.
    public func startCapture() async throws {
        if checkIsRunning() {
            return
        }

        // 1. Verify / request permissions
        let granted = await sessionCoordinator.requestRecordPermission()
        guard granted else {
            throw AudioCaptureError.permissionDenied
        }

        do {
            // 2. Configure audio session
            try sessionCoordinator.configureSession()
            try sessionCoordinator.activateSession()

            // 3. Setup and start audio engine tap
            try setupAudioEngine()
        } catch {
            #if canImport(AVFoundation)
            teardownAudioEngine()
            #endif
            try? sessionCoordinator.deactivateSession()
            throw error
        }

        markRunning()
        sessionCoordinator.markRecording()
    }

    /// Stops audio capture, terminates AVAudioEngine, flushes any remaining accumulated audio as a final chunk,
    /// and deactivates the audio session.
    ///
    /// - Returns: The final emitted AudioChunk, if accumulated samples met the minimum duration threshold.
    @discardableResult
    public func stopCapture() async -> AudioChunk? {
        guard let remainingSamples = prepareStopCapture() else {
            return nil
        }

        #if canImport(AVFoundation)
        teardownAudioEngine()
        #endif

        try? sessionCoordinator.deactivateSession()
        waveformStore.reset()

        let sampleCount = remainingSamples.count
        let duration = Double(sampleCount) / Self.targetSampleRate

        if duration >= minSliceDuration {
            let wavData = WAVEncoder.encode(samples: remainingSamples, sampleRate: Int(Self.targetSampleRate))
            let chunk = AudioChunk(
                samples: remainingSamples,
                wavData: wavData,
                sampleRate: Int(Self.targetSampleRate),
                durationSeconds: duration,
                isFinal: true
            )
            emitChunk(chunk)

            finishContinuation()
            return chunk
        }

        finishContinuation()
        return nil
    }

    /// Pauses audio capture without tearing down the audio session.
    public func pauseCapture() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning && !isPaused else { return }
        isPaused = true

        #if canImport(AVFoundation)
        audioEngine?.pause()
        #endif
        sessionCoordinator.markPaused()
    }

    /// Resumes an active paused capture session.
    public func resumeCapture() throws {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning && isPaused else { return }

        #if canImport(AVFoundation)
        try audioEngine?.start()
        #endif
        isPaused = false
        lastSpeechTimestamp = Date()
        sessionCoordinator.markRecording()
    }

    /// Handles hardware route changes (such as AirPods connection or disconnection)
    /// by safely rebuilding the audio engine graph and converter.
    public func handleAudioRouteChanged() async {
        guard checkIsRunning() else {
            return
        }

        #if canImport(AVFoundation)
        // Safely reconfigure engine with new hardware input format
        teardownAudioEngine()
        do {
            try setupAudioEngine()
        } catch {
            delegate?.audioCaptureDidFail(self, error: error)
        }
        #endif
    }

    // MARK: - Audio Engine Pipeline Setup

    #if canImport(AVFoundation)
    private func setupAudioEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Use outputFormat(forBus: 0) which is the format of the audio flowing out of the input node
        let busFormat = inputNode.outputFormat(forBus: 0)
        let formatToUse: AVAudioFormat
        if busFormat.sampleRate > 0 && busFormat.channelCount > 0 {
            formatToUse = busFormat
        } else {
            formatToUse = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) ?? inputNode.inputFormat(forBus: 0)
        }

        if let target = targetFormat, formatToUse.sampleRate > 0 && formatToUse.channelCount > 0 {
            self.audioConverter = AVAudioConverter(from: formatToUse, to: target)
        }

        self.audioEngine = engine

        let bufferSize: AVAudioFrameCount = 4096

        // Install tap using bus format (or nil if format query is pending engine start)
        let tapFormat = formatToUse.sampleRate > 0 && formatToUse.channelCount > 0 ? formatToUse : nil
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }
            self.processInputBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    private func teardownAudioEngine() {
        guard let engine = audioEngine else { return }
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        audioConverter = nil
    }

    // MARK: - Realtime Audio Processing

    private func processInputBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        lock.lock()
        guard isRunning && !isPaused else {
            lock.unlock()
            return
        }
        guard let target = self.targetFormat else {
            lock.unlock()
            return
        }
        // Dynamically instantiate or adapt converter to incoming buffer format
        if self.audioConverter == nil || self.audioConverter?.inputFormat != inputBuffer.format {
            self.audioConverter = AVAudioConverter(from: inputBuffer.format, to: target)
        }
        guard let converter = self.audioConverter else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Calculate sample conversion ratio
        let sampleRateRatio = Self.targetSampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * sampleRateRatio + 512)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return
        }

        var inputBufferProvided = false
        var conversionError: NSError?

        let status = converter.convert(to: outputBuffer, error: &conversionError) { inNumPackets, outStatus in
            if !inputBufferProvided {
                inputBufferProvided = true
                outStatus.pointee = .haveData
                return inputBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        guard status != .error, conversionError == nil else {
            return
        }

        guard let floatChannelData = outputBuffer.floatChannelData else {
            return
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return }

        // Extract resampled 16kHz mono Float32 samples
        let samples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameCount))

        // Compute power & update waveform store
        let normalizedPower = waveformStore.process(samples: samples)
        let decibels = waveformStore.latestDecibels

        delegate?.audioCaptureDidUpdatePower(self, power: normalizedPower, decibels: decibels)

        // Accumulate and evaluate VAD windowing
        handleAccumulatedSamples(samples, decibels: decibels)
    }
    #endif

    // MARK: - Windowing & VAD Slicing

    private func handleAccumulatedSamples(_ newSamples: [Float], decibels: Float) {
        lock.lock()
        accumulatedSamples.append(contentsOf: newSamples)
        let totalCount = accumulatedSamples.count
        let currentDuration = Double(totalCount) / Self.targetSampleRate

        let now = Date()
        let isSpeech = decibels > silenceDecibelThreshold

        if isSpeech {
            lastSpeechTimestamp = now
            hasDetectedSpeechInCurrentSlice = true
        }

        var shouldEmitSlice = false
        var emitReason = ""

        // 1. Mandatory max window slice (e.g. 15.0 seconds = 240,000 samples)
        if (totalCount >= Self.samplesPer15Seconds || currentDuration >= maxSliceDuration),
           hasDetectedSpeechInCurrentSlice {
            shouldEmitSlice = true
            emitReason = "Max window duration reached (15s / 240,000 samples)"
        }
        // 2. VAD Silence Hangover (speech was active, now silence sustained for >= threshold)
        else if hasDetectedSpeechInCurrentSlice && currentDuration >= minSliceDuration {
            let silenceDuration = now.timeIntervalSince(lastSpeechTimestamp)
            if silenceDuration >= silenceThresholdDuration {
                shouldEmitSlice = true
                emitReason = "VAD end-of-utterance silence detected (\(silenceDuration)s)"
            }
        }

        guard shouldEmitSlice else {
            lock.unlock()
            return
        }

        #if canImport(OSLog)
        let logger = Logger(subsystem: "com.edgeeloquent", category: "UnifiedAudioCapture")
        logger.debug("Emitting audio slice: \(emitReason, privacy: .public)")
        #endif

        // Extract slice samples and reset buffer
        let sliceSamples = accumulatedSamples
        accumulatedSamples.removeAll(keepingCapacity: true)
        hasDetectedSpeechInCurrentSlice = false
        lastSpeechTimestamp = now
        lock.unlock()

        let sliceDuration = Double(sliceSamples.count) / Self.targetSampleRate
        guard sliceDuration >= minSliceDuration else {
            return
        }

        // Fast in-memory WAV encoding with 44-byte RIFF header
        let wavData = WAVEncoder.encode(samples: sliceSamples, sampleRate: Int(Self.targetSampleRate))
        let chunk = AudioChunk(
            samples: sliceSamples,
            wavData: wavData,
            sampleRate: Int(Self.targetSampleRate),
            durationSeconds: sliceDuration,
            isFinal: false
        )

        emitChunk(chunk)
    }

    private func emitChunk(_ chunk: AudioChunk) {
        lock.lock()
        let continuation = chunkStreamContinuation
        lock.unlock()
        continuation?.yield(chunk)
        delegate?.audioCaptureDidEmitChunk(self, chunk: chunk)
    }

    private func stopCaptureSync() {
        #if canImport(AVFoundation)
        teardownAudioEngine()
        #endif
        chunkStreamContinuation?.finish()
        chunkStreamContinuation = nil
    }
}

extension UnifiedAudioCapture: AudioSessionCoordinatorDelegate {
    public func audioSessionDidChangeState(_ coordinator: AudioSessionCoordinator, state: AudioSessionState) {}

    public func audioSessionDidReceiveInterruption(
        _ coordinator: AudioSessionCoordinator,
        interruption: AudioInterruptionType
    ) {}

    public func audioSessionDidReceiveRouteChange(
        _ coordinator: AudioSessionCoordinator,
        reason: AudioRouteChangeReason,
        currentRoute: String
    ) {
        Task { await handleAudioRouteChanged() }
    }

    public func audioSessionDidFail(_ coordinator: AudioSessionCoordinator, error: Error) {
        delegate?.audioCaptureDidFail(self, error: error)
    }
}
