//
//  AppleOnDeviceSpeechEngine.swift
//  EdgeEloquent
//
//  Created by ModelAgent on 2026-09-08.
//

import Foundation
import OSLog

#if canImport(Speech)
import Speech
import AVFoundation
#endif

/// Zero-download fallback speech transcription engine using Apple's native Speech framework (`SFSpeechRecognizer`).
/// Requires 0 MB of downloaded model weights and operates with ultra-low RAM footprint.
/// Strictly enforces the Audio Air-Gap Invariant by mandating `requiresOnDeviceRecognition = true`.
public final class AppleOnDeviceSpeechEngine: SpeechModelEngine, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.edgeeloquent.engine", category: "AppleOnDeviceSpeechEngine")
    
    /// Model metadata representing the native platform speech recognizer.
    public let modelInfo: ModelInfo
    
    /// Target locale for speech recognition (defaults to current system locale).
    public let locale: Locale
    
    private let lock = NSLock()
    private var _isLoaded: Bool = false
    
    #if canImport(Speech)
    private var speechRecognizer: SFSpeechRecognizer?
    private var activeTask: SFSpeechRecognitionTask?
    #endif
    
    public var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isLoaded
    }
    
    /// Designated Initializer
    /// - Parameters:
    ///   - modelInfo: Preset metadata (defaults to `ModelInfo.appleNative`).
    ///   - locale: Locale for transcription (e.g. `Locale(identifier: "en-US")`).
    public init(
        modelInfo: ModelInfo = .appleNative,
        locale: Locale = Locale.current
    ) {
        self.modelInfo = modelInfo
        self.locale = locale
    }
    
    // MARK: - Lifecycle Management
    
    /// Pre-warms the native Apple speech recognition subsystem and validates permissions.
    public func load() async throws {
        lock.lock()
        if _isLoaded {
            lock.unlock()
            return
        }
        lock.unlock()
        
        logger.info("Initializing AppleOnDeviceSpeechEngine for locale \(self.locale.identifier)...")
        
        #if canImport(Speech)
        // Verify authorization status
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        switch authStatus {
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            guard granted else {
                throw SpeechModelEngineError.speechRecognitionPermissionDenied
            }
        case .authorized:
            break
        case .denied, .restricted:
            throw SpeechModelEngineError.speechRecognitionPermissionDenied
        @unknown default:
            throw SpeechModelEngineError.speechRecognitionPermissionDenied
        }
        
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            logger.error("SFSpeechRecognizer is unavailable for locale: \(self.locale.identifier)")
            throw SpeechModelEngineError.speechRecognitionUnavailable
        }
        
        guard recognizer.isAvailable else {
            logger.error("SFSpeechRecognizer is currently unavailable on device.")
            throw SpeechModelEngineError.speechRecognitionUnavailable
        }
        
        // Ensure on-device transcription is supported for this locale
        if #available(iOS 13.0, macOS 10.15, *) {
            if !recognizer.supportsOnDeviceRecognition {
                logger.warning("Locale \(self.locale.identifier) does not support on-device recognition. Network may be required by OS.")
            }
        }
        
        lock.lock()
        self.speechRecognizer = recognizer
        self._isLoaded = true
        lock.unlock()
        
        logger.info("AppleOnDeviceSpeechEngine loaded successfully.")
        #else
        // Non-Apple platform fallback simulation
        lock.lock()
        self._isLoaded = true
        lock.unlock()
        logger.info("AppleOnDeviceSpeechEngine loaded (simulation mode).")
        #endif
    }
    
    /// Unloads the engine and terminates any active recognition tasks.
    public func unload() async {
        lock.lock()
        guard _isLoaded else {
            lock.unlock()
            return
        }
        
        #if canImport(Speech)
        activeTask?.cancel()
        activeTask = nil
        speechRecognizer = nil
        #endif
        
        _isLoaded = false
        lock.unlock()
        
        await Task.yield()
        logger.info("AppleOnDeviceSpeechEngine unloaded.")
    }
    
    // MARK: - Transcription Execution
    
    /// Transcribes 16kHz mono Linear PCM WAV data using Apple's on-device speech recognizer.
    /// Streams partial recognition hypotheses as text increments.
    public func transcribeAudio(
        wavData: Data,
        prompt: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        lock.lock()
        guard _isLoaded else {
            lock.unlock()
            throw SpeechModelEngineError.modelNotLoaded
        }
        lock.unlock()
        
        guard wavData.count > 44 else {
            throw SpeechModelEngineError.invalidAudioFormat(reason: "WAV buffer too small (\(wavData.count) bytes).")
        }
        
        // Write audio bytes to temporary file for SFSpeechURLRecognitionRequest
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EdgeEloquent/apple_speech", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempWavURL = tempDir.appendingPathComponent("\(UUID().uuidString).wav")
        try wavData.write(to: tempWavURL)
        
        return AsyncThrowingStream { continuation in
            #if canImport(Speech)
            guard let recognizer = self.speechRecognizer else {
                continuation.finish(throwing: SpeechModelEngineError.modelNotLoaded)
                try? FileManager.default.removeItem(at: tempWavURL)
                return
            }
            
            let request = SFSpeechURLRecognitionRequest(url: tempWavURL)
            
            // STRICT PRIVACY INVARIANT: Mandate on-device recognition
            if #available(iOS 13.0, macOS 10.15, *) {
                request.requiresOnDeviceRecognition = true
            }
            
            // Real-time incremental reporting
            request.shouldReportPartialResults = true
            
            // Apply contextual prompt strings if supplied
            if let prompt = prompt, !prompt.isEmpty {
                request.contextualStrings = prompt.components(separatedBy: .whitespacesAndNewlines)
            }
            
            var previousTextLength = 0
            
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    try? FileManager.default.removeItem(at: tempWavURL)
                    continuation.finish(throwing: SpeechModelEngineError.transcriptionFailed(reason: error.localizedDescription))
                    return
                }
                
                guard let result = result else { return }
                
                let currentFullText = result.bestTranscription.formattedString
                if currentFullText.count > previousTextLength {
                    let startIndex = currentFullText.index(currentFullText.startIndex, offsetBy: previousTextLength)
                    let newChunk = String(currentFullText[startIndex...])
                    continuation.yield(newChunk)
                    previousTextLength = currentFullText.count
                }
                
                if result.isFinal {
                    try? FileManager.default.removeItem(at: tempWavURL)
                    continuation.finish()
                }
            }
            
            self.lock.lock()
            self.activeTask = task
            self.lock.unlock()
            
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                try? FileManager.default.removeItem(at: tempWavURL)
            }
            #else
            // Fallback mock stream for non-Apple compilation environments
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continuation.yield("Native Apple speech transcription ")
                continuation.yield("completed on-device.")
                try? FileManager.default.removeItem(at: tempWavURL)
                continuation.finish()
            }
            #endif
        }
    }
}
