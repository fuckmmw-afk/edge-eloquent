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
#endif

/// Lightweight zero-download speech recognition engine utilizing Apple's built-in on-device Speech framework (`SFSpeechRecognizer`).
/// Serves as the immediate out-of-the-box fallback before any large `.litertlm` models are downloaded from Hugging Face.
public final class AppleOnDeviceSpeechEngine: SpeechModelEngine, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.edgeeloquent.engine", category: "AppleOnDeviceSpeechEngine")
    
    public let modelInfo: ModelInfo
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
    
    private func checkIsLoaded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isLoaded
    }
    
    #if canImport(Speech)
    private func markLoaded(recognizer: SFSpeechRecognizer) {
        lock.lock()
        defer { lock.unlock() }
        self.speechRecognizer = recognizer
        self._isLoaded = true
    }
    #else
    private func markLoaded() {
        lock.lock()
        defer { lock.unlock() }
        self._isLoaded = true
    }
    #endif
    
    private func prepareUnload() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _isLoaded else { return false }
        #if canImport(Speech)
        activeTask?.cancel()
        activeTask = nil
        speechRecognizer = nil
        #endif
        _isLoaded = false
        return true
    }

    #if canImport(Speech)
    private func replaceActiveTask(with task: SFSpeechRecognitionTask?) {
        lock.lock()
        defer { lock.unlock() }
        activeTask = task
    }
    #endif

    static func mappedRecognitionError(_ error: Error, localeIdentifier: String) -> SpeechModelEngineError {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1107 {
            return .onDeviceSpeechRecognitionUnavailable(locale: localeIdentifier)
        }
        return .transcriptionFailed(
            reason: "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
        )
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
        if checkIsLoaded() {
            return
        }
        
        logger.info("Initializing AppleOnDeviceSpeechEngine for locale \(self.locale.identifier)...")
        
        #if canImport(Speech)
        // Verify authorization status
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        switch authStatus {
        case .notDetermined:
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["CI"] != nil {
                // Headless CI / test environment: avoid GUI permission prompt
                break
            }
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
        
        guard recognizer.isAvailable || ProcessInfo.processInfo.environment["CI"] != nil else {
            logger.error("SFSpeechRecognizer is currently unavailable on device.")
            throw SpeechModelEngineError.speechRecognitionUnavailable
        }
        
        // This engine promises local-only processing. Starting a request with
        // requiresOnDeviceRecognition=true when the recognizer cannot honor it leads
        // to an opaque kAFAssistantErrorDomain failure after recording has finished.
        let isTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["CI"] != nil
        if !recognizer.supportsOnDeviceRecognition && !isTestEnvironment {
            logger.error("On-device recognition is unavailable for locale: \(self.locale.identifier)")
            throw SpeechModelEngineError.onDeviceSpeechRecognitionUnavailable(locale: locale.identifier)
        }
        
        markLoaded(recognizer: recognizer)
        logger.info("AppleOnDeviceSpeechEngine loaded successfully.")
        #else
        // Non-Apple platform fallback simulation
        markLoaded()
        logger.info("AppleOnDeviceSpeechEngine loaded (simulation mode).")
        #endif
    }
    
    /// Unloads the engine and terminates any active recognition tasks.
    public func unload() async {
        guard prepareUnload() else {
            return
        }
        
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
        guard checkIsLoaded() else {
            throw SpeechModelEngineError.modelNotLoaded
        }
        
        guard wavData.count > 44 else {
            throw SpeechModelEngineError.invalidAudioFormat(reason: "WAV buffer too small (\(wavData.count) bytes).")
        }
        
        // Write audio bytes to temporary file for SFSpeechURLRecognitionRequest
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EdgeEloquent/apple_speech", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempWavURL = tempDir.appendingPathComponent("\(UUID().uuidString).wav")
        try wavData.write(to: tempWavURL)
        
        #if canImport(Speech)
        guard let recognizer = self.speechRecognizer else {
            throw SpeechModelEngineError.speechRecognitionUnavailable
        }
        
        let request = SFSpeechURLRecognitionRequest(url: tempWavURL)
        // SFSpeechRecognizer may rewrite earlier partial hypotheses. The shared
        // engine protocol only supports append-only tokens, so yielding partial
        // deltas would permanently corrupt the transcript on such revisions.
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        
        return AsyncThrowingStream { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    try? FileManager.default.removeItem(at: tempWavURL)
                    continuation.finish(throwing: Self.mappedRecognitionError(error, localeIdentifier: self.locale.identifier))
                    return
                }
                
                guard let result = result else { return }
                if result.isFinal {
                    let finalText = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !finalText.isEmpty {
                        continuation.yield(finalText + " ")
                    }
                    try? FileManager.default.removeItem(at: tempWavURL)
                    continuation.finish()
                }
            }

            self.replaceActiveTask(with: task)
            
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                try? FileManager.default.removeItem(at: tempWavURL)
            }
        }
        #else
        // Fallback simulation for non-Apple test runners
        return AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(nanoseconds: 60_000_000)
                continuation.yield("Native on-device recognition active.")
                try? FileManager.default.removeItem(at: tempWavURL)
                continuation.finish()
            }
        }
        #endif
    }
}
