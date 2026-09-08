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
    @Published public var activeEngineName: String = "Gemma-4-E2B-it"
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
    private var accumulatedTokens: [String] = []

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
        } else if let firstReady = modelManager.downloadedModels.first {
            self.activeEngineName = firstReady.name
        } else {
            self.activeEngineName = "Apple Native Speech"
        }
    }

    /// Resolves or instantiates the speech model engine for dictation.
    private func resolveEngine() async throws -> SpeechModelEngine {
        updateActiveEngineName()

        // If active model is a downloaded LiteRT model
        if let active = modelManager.activeModel {
            let fileURL = modelManager.modelFileURL(for: active)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                // Map SupportedAudioModel to ModelInfo
                let info = ModelInfo.allSupportedModels.first(where: { $0.id == active.id || $0.modelId == active.id }) ?? ModelInfo.defaultModel

                // If existing activeEngine is for a different model, unload it first
                if let existing = activeEngine {
                    if existing.modelInfo.id == info.id && existing.isLoaded {
                        return existing
                    }
                    await existing.unload()
                    self.activeEngine = nil
                }

                let engine = LiteRTGemmaEngine(modelInfo: info, modelPath: fileURL.path)
                try await engine.load()
                self.activeEngine = engine
                return engine
            }
        }

        // Apple Native Speech or fallback
        if let existing = activeEngine {
            if existing.modelInfo.id == ModelInfo.appleNative.id && existing.isLoaded {
                return existing
            }
            await existing.unload()
            self.activeEngine = nil
        }

        let fallback = AppleOnDeviceSpeechEngine()
        try await fallback.load()
        self.activeEngine = fallback
        return fallback
    }

    // MARK: - Dictation Actions

    /// Starts recording audio and streams live transcription tokens.
    public func startRecording() {
        guard !state.isRecording && !state.isProcessing else { return }

        // Reset session state
        realtimePartialTranscript = ""
        finalizedTranscript = ""
        accumulatedTokens = []
        currentDuration = 0.0
        activeRecord = nil
        lastErrorMessage = nil
        recordingStartTime = Date()

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

        // Start capture and listen to audio chunk stream
        Task {
            do {
                let engine = try await resolveEngine()
                try await audioCapture.startCapture()

                // Process continuous audio chunks emitted by UnifiedAudioCapture
                streamProcessingTask = Task { [weak self] in
                    guard let self = self else { return }
                    for await chunk in self.audioCapture.chunkStream {
                        guard !Task.isCancelled else { break }
                        do {
                            let tokenStream = try await engine.transcribeAudio(wavData: chunk.wavData, prompt: nil)
                            for try await token in tokenStream {
                                guard !Task.isCancelled else { break }
                                await MainActor.run {
                                    self.accumulatedTokens.append(token)
                                    self.realtimePartialTranscript = self.accumulatedTokens.joined()
                                }
                            }
                        } catch {
                            print("[DictationCoordinator] Chunk transcription warning: \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
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
            // 1. Terminate audio capture (UnifiedAudioCapture.stopCapture flushes any remaining chunk to chunkStream and finishes it)
            _ = await audioCapture.stopCapture()

            // 2. Wait for the background stream processing task to finish draining all emitted chunks
            if let task = streamProcessingTask {
                _ = await task.result
            }
            streamProcessingTask = nil

            var rawTranscript = accumulatedTokens.joined().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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
                cleanTranscript: cleanTranscript,
                finalText: finalText,
                modelUsed: activeEngineName,
                durationSeconds: finalDuration,
                isEnhanced: isEnhanced
            )

            historyStore.saveRecord(record)

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
