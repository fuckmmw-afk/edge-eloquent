//
//  DictationCoordinator.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Coordinates the end-to-end dictation pipeline:
//  UnifiedAudioCapture -> SpeechModelEngine -> LocalTranscriptCleaner -> CloudflareBrainService -> TranscriptionHistoryStore.
//

import Foundation
import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Current stage during post-recording speech synthesis and text enhancement.
public enum ProcessingStage: String, Sendable, Equatable {
    case transcribing = "Transcribing Speech..."
    case cleaning = "Applying Local Cleanup..."
    case enhancing = "Enhancing with Cloudflare AI..."
}

/// Overall lifecycle state of the dictation session.
public enum DictationState: Equatable, Sendable {
    case idle
    case recording(duration: TimeInterval)
    case processing(stage: ProcessingStage)
    case completed(record: TranscriptionRecord)
    case error(message: String)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    public var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }

    public var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

/// Primary coordinator orchestrating microphone capture, model inference,
/// local rule-based cleanup, Cloudflare edge enhancement, and local history persistence.
@MainActor
public final class DictationCoordinator: ObservableObject {

    // MARK: - Published State

    @Published public var state: DictationState = .idle
    @Published public var realtimePartialTranscript: String = ""
    @Published public var finalizedTranscript: String = ""
    @Published public var liveWaveformLevels: [Float] = []
    @Published public var currentDuration: TimeInterval = 0.0
    @Published public var activeRecord: TranscriptionRecord? = nil
    @Published public var activeEngineName: String = "Apple Native Speech"
    @Published public var lastErrorMessage: String? = nil

    // MARK: - Dependencies

    public let audioCapture: UnifiedAudioCapture
    public let modelManager: ModelManager
    public let historyStore: TranscriptionHistoryStore
    public let appConfig: AppConfig

    // MARK: - Private State

    private var activeEngine: SpeechModelEngine?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private var streamProcessingTask: Task<Void, Never>?
    private var captureStartTask: Task<Void, Never>?
    private var accumulatedTokens: [String] = []
    private var streamError: Error?

    // MARK: - Initialization

    public convenience init() {
        self.init(
            audioCapture: UnifiedAudioCapture(),
            modelManager: ModelManager(),
            historyStore: .shared,
            appConfig: .shared
        )
    }

    public convenience init(
        modelManager: ModelManager,
        historyStore: TranscriptionHistoryStore,
        appConfig: AppConfig
    ) {
        self.init(
            audioCapture: UnifiedAudioCapture(),
            modelManager: modelManager,
            historyStore: historyStore,
            appConfig: appConfig
        )
    }

    public init(
        audioCapture: UnifiedAudioCapture,
        modelManager: ModelManager,
        historyStore: TranscriptionHistoryStore,
        appConfig: AppConfig
    ) {
        self.audioCapture = audioCapture
        self.modelManager = modelManager
        self.historyStore = historyStore
        self.appConfig = appConfig

        // Observe waveform changes
        self.audioCapture.waveformStore.onPowerLevelUpdated = { [weak self] _, history in
            Task { @MainActor [weak self] in
                self?.liveWaveformLevels = history
            }
        }

        self.updateActiveEngineName()
    }

    // MARK: - Active Engine Resolution

    /// Updates the display name of the currently active model.
    public func updateActiveEngineName() {
        if let activeModel = modelManager.activeModel {
            self.activeEngineName = activeModel.name
        } else if modelManager.activeModelId == "apple-native-speech" {
            self.activeEngineName = "Apple Native Speech"
        } else {
            self.activeEngineName = "Apple Native Speech"
        }
    }

    /// Resolves or instantiates the speech model engine for dictation.
    private func resolveEngine() async throws -> SpeechModelEngine {
        updateActiveEngineName()

        // Apple Speech is used only when the user selected it explicitly or no local
        // Gemma model has ever been selected. A LiteRT failure must never be hidden by
        // silently changing engines: doing so masks the actionable model error and can
        // send the recording into an unavailable Apple recognizer for the current locale.
        guard let selectedModelId = modelManager.activeModelId else {
            return try await resolveAppleEngine()
        }

        if selectedModelId == "apple-native-speech" {
            return try await resolveAppleEngine()
        }

        guard let active = modelManager.activeModel else {
            throw SpeechModelEngineError.engineInitializationFailed(
                reason: "Selected model \(selectedModelId) is missing or incomplete. Re-download it in Model Manager."
            )
        }

        guard modelManager.isModelDownloaded(active) else {
            throw SpeechModelEngineError.engineInitializationFailed(
                reason: "Selected model \(active.name) failed its local integrity check. Re-download it in Model Manager."
            )
        }

        let info = ModelInfo(supportedModel: active)
        if let existing = activeEngine {
            if existing.modelInfo.id == info.id && existing.isLoaded {
                return existing
            }
            await existing.unload()
            self.activeEngine = nil
        }

        let fileURL = modelManager.modelFileURL(for: active)
        let engine = LiteRTGemmaEngine(modelInfo: info, modelPath: fileURL.path)
        do {
            try await engine.load()
            self.activeEngine = engine
            self.activeEngineName = active.name
            return engine
        } catch let error as SpeechModelEngineError {
            throw error
        } catch {
            throw SpeechModelEngineError.engineInitializationFailed(
                reason: "\(active.name): \(error.localizedDescription)"
            )
        }
    }

    private func resolveAppleEngine() async throws -> SpeechModelEngine {
        if let existing = activeEngine {
            if existing.modelInfo.id == ModelInfo.appleNative.id && existing.isLoaded {
                return existing
            }
            await existing.unload()
            self.activeEngine = nil
        }

        let engine = AppleOnDeviceSpeechEngine()
        try await engine.load()
        self.activeEngine = engine
        self.activeEngineName = engine.modelInfo.name
        return engine
    }

    // MARK: - Dictation Actions

    /// Starts recording audio and streams live transcription tokens.
    public func startRecording() {
        guard !state.isRecording && !state.isProcessing else { return }

        // Reset session state
        realtimePartialTranscript = ""
        finalizedTranscript = ""
        accumulatedTokens = []
        streamError = nil
        currentDuration = 0.0
        activeRecord = nil
        lastErrorMessage = nil
        recordingStartTime = Date()

        // Some dedicated ASR conversions have a fixed acoustic input length. In
        // particular, Qwen3-ASR-0.6B is exported for five-second windows; sending
        // the generic 15-second window can produce empty output or shape errors.
        let audioWindow = modelManager.activeModel?.recommendedAudioWindowSeconds ?? 15.0
        audioCapture.setMaxSliceDuration(audioWindow)

        state = .recording(duration: 0.0)

        // Start duration timer
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.recordingStartTime else { return }
                let elapsed = Date().timeIntervalSince(start)
                self.currentDuration = elapsed
                if self.state.isRecording {
                    self.state = .recording(duration: elapsed)
                }
            }
        }

        // Register the stream before starting AVAudioEngine. Previously the continuation was
        // installed only after model initialization and capture startup, so early/final chunks
        // could be dropped. More importantly, a cold multi-gigabyte model was loaded before the
        // microphone started even though the UI already said "Recording".
        captureStartTask?.cancel()
        captureStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                let chunkStream = audioCapture.chunkStream
                try await audioCapture.startCapture()
                if Task.isCancelled {
                    _ = await audioCapture.stopCapture()
                    return
                }

                // Load/resolve the model while the microphone is already recording. AsyncStream
                // buffers chunks emitted during a cold model start and drains them in order.
                streamProcessingTask = Task { [weak self] in
                    guard let self = self else { return }
                    do {
                        let engine = try await self.resolveEngine()
                        for await chunk in chunkStream {
                            try Task.checkCancellation()
                            let tokenStream = try await engine.transcribeAudio(wavData: chunk.wavData, prompt: nil)
                            for try await token in tokenStream {
                                try Task.checkCancellation()
                                await MainActor.run {
                                    self.accumulatedTokens.append(token)
                                    self.realtimePartialTranscript = self.accumulatedTokens.joined()
                                }
                            }
                        }
                    } catch {
                        if error is CancellationError { return }
                        await MainActor.run {
                            self.streamError = error
                            self.lastErrorMessage = error.localizedDescription
                        }
                        print("[DictationCoordinator] Speech processing failed: \(error.localizedDescription)")
                    }
                }
            } catch {
                if error is CancellationError { return }
                await MainActor.run {
                    self.durationTimer?.invalidate()
                    self.durationTimer = nil
                    self.lastErrorMessage = error.localizedDescription
                    self.state = .error(message: error.localizedDescription)
                }
            }
        }
    }

    /// Stops audio capture and executes the post-processing pipeline:
    /// Local cleanup -> Cloudflare AI enhancement -> History store persistence.
    public func stopRecording() {
        guard state.isRecording else { return }

        durationTimer?.invalidate()
        durationTimer = nil
        let finalDuration = currentDuration

        state = .processing(stage: .transcribing)

        Task { [self] in
            // If Stop was tapped while permissions/model loading were still in progress,
            // wait until startup has either completed or failed before tearing capture down.
            if let task = captureStartTask {
                await task.value
            }
            captureStartTask = nil
            if case .error = state {
                return
            }

            // 1. Terminate audio capture (UnifiedAudioCapture.stopCapture flushes any remaining chunk to chunkStream and finishes it)
            _ = await audioCapture.stopCapture()

            // 2. Wait for the background stream processing task to finish draining all emitted chunks
            if let task = streamProcessingTask {
                _ = await task.result
            }
            streamProcessingTask = nil

            var rawTranscript = accumulatedTokens.joined().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if rawTranscript.isEmpty, let error = streamError {
                lastErrorMessage = error.localizedDescription
                state = .error(message: error.localizedDescription)
                return
            }
            if rawTranscript.isEmpty {
                // If microphone picked up only silence, provide graceful fallback
                rawTranscript = "No audible speech detected."
            }

            self.finalizedTranscript = rawTranscript
            self.realtimePartialTranscript = ""

            // 3. Stage 2: Local Transcript Cleanup
            await MainActor.run {
                self.state = .processing(stage: .cleaning)
            }

            var cleanTranscript = rawTranscript
            if appConfig.isLocalCleanupEnabled && rawTranscript != "No audible speech detected." {
                cleanTranscript = LocalTranscriptCleaner.cleanText(rawTranscript, isFinal: true)
            }

            // 4. Stage 3: Cloudflare Enhancement Pass (if enabled)
            var finalText = cleanTranscript
            var isEnhanced = false

            if appConfig.isCloudflareEnhancementEnabled,
               let cfURL = appConfig.resolvedCloudflareURL,
               cleanTranscript != "No audible speech detected." {
                await MainActor.run {
                    self.state = .processing(stage: .enhancing)
                }

                let cfConfig = CloudflareConfiguration(
                    endpointURL: cfURL,
                    apiToken: appConfig.cloudflareAPIToken.isEmpty ? nil : appConfig.cloudflareAPIToken,
                    timeoutInterval: appConfig.requestTimeout
                )
                let brainService = CloudflareBrainService(configuration: cfConfig)

                do {
                    let response = try await brainService.enhance(
                        text: cleanTranscript,
                        mode: appConfig.enhancementMode,
                        enableWebSearch: appConfig.enableWebSearch
                    )
                    finalText = response.enhancedText
                    isEnhanced = true
                } catch {
                    print("[DictationCoordinator] Cloudflare enhancement skipped/failed: \(error.localizedDescription). Falling back to clean transcript.")
                }
            }

            // 5. Stage 4: Local History Store Persistence
            let record = TranscriptionRecord(
                rawTranscript: rawTranscript,
                cleanTranscript: cleanTranscript,
                finalText: finalText,
                modelUsed: activeEngineName,
                durationSeconds: finalDuration,
                isEnhanced: isEnhanced
            )

            historyStore.saveRecord(record)
            if let persistenceError = historyStore.lastPersistenceError {
                lastErrorMessage = persistenceError
                state = .error(message: persistenceError)
                return
            }

            // Auto-copy to clipboard if configured
            if appConfig.autoCopyToClipboard {
                self.copyToClipboard(text: record.displayText)
            }

            await MainActor.run {
                self.activeRecord = record
                self.state = .completed(record: record)
            }
        }
    }

    /// Cancels the current recording without persisting to history.
    public func cancelRecording() {
        durationTimer?.invalidate()
        durationTimer = nil
        captureStartTask?.cancel()
        captureStartTask = nil
        streamProcessingTask?.cancel()
        streamProcessingTask = nil

        Task {
            _ = await audioCapture.stopCapture()
            await MainActor.run {
                self.realtimePartialTranscript = ""
                self.finalizedTranscript = ""
                self.accumulatedTokens = []
                self.liveWaveformLevels = []
                self.state = .idle
            }
        }
    }

    /// Clears the active completed result card and returns to idle state.
    public func clearResult() {
        activeRecord = nil
        realtimePartialTranscript = ""
        finalizedTranscript = ""
        state = .idle
    }

    /// Copies given text to system clipboard with haptic feedback.
    public func copyToClipboard(text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif
    }
}
