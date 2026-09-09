//
//  LiteRTGemmaEngine.swift
//  EdgeEloquent
//
//  Created by ModelAgent on 2026-09-08.
//

import Foundation
import OSLog

import LiteRTLM

// MARK: - LiteRTGemmaEngine Implementation

/// Production speech comprehension engine powered by Google AI Edge's LiteRT-LM runtime (`CLiteRTLM.xcframework`).
/// Directly executes Gemma 3n and Gemma 4 multimodal models on Apple Silicon unified memory using split backends:
/// - Metal MSL GPU compute for autoregressive LLM projection
/// - ARM NEON CPU vectorization for Conformer acoustic feature extraction
public final class LiteRTGemmaEngine: SpeechModelEngine, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.edgeeloquent.engine", category: "LiteRTGemmaEngine")
    
    /// Model metadata and capability specification.
    public let modelInfo: ModelInfo
    
    /// Target path to the `.litertlm` artifact on local device storage.
    public let customModelPath: String?
    
    /// Directory for caching compiled Metal compute pipeline states.
    public let cacheDirectory: URL?
    
    /// Strategy for feeding audio into the engine: a filesystem path (`Content.audioFile`)
    /// or in-memory base64 (`Content.audioData`). The file path is the default because it is
    /// the path exercised by LiteRT-LM's native audio examples and avoids a large JSON/base64 copy.
    public let useAudioFilePassing: Bool
    
    // Concurrency synchronization lock
    private let lock = NSLock()
    private var _isLoaded: Bool = false
    private var _engine: Engine?
    private var _activeConversation: Conversation?
    
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
    
    private func markLoaded(engine: Engine) {
        lock.lock()
        defer { lock.unlock() }
        self._engine = engine
        self._isLoaded = true
    }
    
    private func prepareUnload() -> (Conversation?, Engine?)? {
        lock.lock()
        defer { lock.unlock() }
        guard _isLoaded else { return nil }
        let conversation = _activeConversation
        let engine = _engine
        self._activeConversation = nil
        self._engine = nil
        self._isLoaded = false
        return (conversation, engine)
    }
    
    private func loadedEngine() throws -> Engine {
        lock.lock()
        defer { lock.unlock() }
        guard _isLoaded, let engine = _engine else {
            throw SpeechModelEngineError.modelNotLoaded
        }
        return engine
    }

    private func registerConversation(_ conversation: Conversation, for engine: Engine) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _isLoaded, _engine === engine else { return false }
        _activeConversation = conversation
        return true
    }

    private func prepareConversation() async throws -> Conversation {
        let engine = try loadedEngine()
        let conversation = try await engine.createConversation()
        guard registerConversation(conversation, for: engine) else {
            try? conversation.cancel()
            throw SpeechModelEngineError.modelNotLoaded
        }
        return conversation
    }
    
    /// Resolved path to the `.litertlm` file on device.
    public var resolvedModelPath: String {
        if let custom = customModelPath {
            return custom
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let basePath = appSupport.appendingPathComponent("EdgeEloquent", isDirectory: true)
        return basePath.appendingPathComponent(modelInfo.localRelativePath).path
    }
    
    /// Designated Initializer
    ///
    /// - Parameters:
    ///   - modelInfo: Specification of the target Gemma model (e.g. `ModelInfo.gemma4_E2B`).
    ///   - modelPath: Optional explicit path to the `.litertlm` file. Defaults to Application Support sandbox.
    ///   - cacheDirectory: Optional cache directory for Metal pipelines. Defaults to Caches/LiteRTCache.
    ///   - useAudioFilePassing: Whether to serialize audio to a temporary file (`Content.audioFile`) instead of memory (`Content.audioData`).
    public init(
        modelInfo: ModelInfo,
        modelPath: String? = nil,
        cacheDirectory: URL? = nil,
        useAudioFilePassing: Bool = true
    ) {
        self.modelInfo = modelInfo
        self.customModelPath = modelPath
        self.cacheDirectory = cacheDirectory
        self.useAudioFilePassing = useAudioFilePassing
    }
    
    // MARK: - Lifecycle Management
    
    /// Asynchronously initializes LiteRT-LM engine, maps weights via POSIX mmap, and compiles Metal shaders.
    public func load() async throws {
        if checkIsLoaded() {
            logger.warning("Engine for \(self.modelInfo.name) is already loaded.")
            return
        }
        
        let path = resolvedModelPath
        logger.info("Verifying model artifact at path: \(path)")
        
        guard FileManager.default.fileExists(atPath: path) else {
            logger.error("Model file not found: \(path)")
            throw SpeechModelEngineError.modelFileNotFound(path: path)
        }
        
        // Memory diagnostic check
        let physicalRam = ProcessInfo.processInfo.physicalMemory
        let physicalRamGb = Int(ceil(Double(physicalRam) / (1024.0 * 1024.0 * 1024.0)))
        if physicalRamGb < modelInfo.minDeviceMemoryInGb {
            throw SpeechModelEngineError.insufficientDeviceMemory(
                requiredGb: modelInfo.minDeviceMemoryInGb,
                availableGb: physicalRamGb
            )
        }
        
        // Configure compilation cache
        let cachePath: String
        if let cacheDirectory = cacheDirectory {
            cachePath = cacheDirectory.path
        } else {
            let defaultCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("LiteRTCache", isDirectory: true)
                .appendingPathComponent(modelInfo.id, isDirectory: true)
            try? FileManager.default.createDirectory(at: defaultCache, withIntermediateDirectories: true)
            cachePath = defaultCache.path
        }
        
        logger.info("Initializing LiteRT-LM EngineConfig with Split Backend: GPU (LLM), CPU (Audio)")
        
        // Split-backend configuration:
        // LLM decoder -> .gpu (Apple Metal Shading Language compute)
        // Audio Conformer -> .cpu() (ARM NEON vectorization)
        // Vision Projector -> .gpu (Metal)
        let config = try EngineConfig(
            modelPath: path,
            backend: .gpu,
            visionBackend: modelInfo.supportsVision ? .gpu : nil,
            audioBackend: .cpu(),
            maxNumTokens: modelInfo.maxContextTokens,
            cacheDir: cachePath
        )
        
        let engine = Engine(engineConfig: config)
        
        do {
            try await engine.initialize()
            markLoaded(engine: engine)
            logger.info("LiteRT-LM Engine initialized successfully for \(self.modelInfo.name)")
        } catch {
            logger.error("Failed to initialize LiteRT-LM Engine: \(error.localizedDescription)")
            throw SpeechModelEngineError.engineInitializationFailed(reason: error.localizedDescription)
        }
    }
    
    /// Unloads the engine, invalidates conversations, releases Metal pipelines, and yields for VM page reclamation.
    public func unload() async {
        guard let (conversation, engine) = prepareUnload() else {
            return
        }
        
        logger.info("Unloading LiteRT-LM engine for \(self.modelInfo.name)...")
        
        // Cancel active conversation
        if let conversation = conversation {
            try? conversation.cancel()
        }
        
        // Terminate native engine handle
        _ = engine // Native deinit releases the LiteRT-LM engine handle.
        
        // Force cooperative yield to allow Darwin VM to collect unmapped pages
        await Task.yield()
        logger.info("LiteRT-LM engine deallocated. Resident memory freed.")
    }
    
    // MARK: - Transcription Execution
    
    /// Transcribes 16kHz mono Linear PCM WAV data into streaming tokens.
    /// Enforces the immutable multimodal message ordering rule: audio node strictly precedes prompt text!
    public func transcribeAudio(
        wavData: Data,
        prompt: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        let conversation = try await prepareConversation()
        
        // Reject malformed buffers before they reach the native audio preprocessor. A byte-count
        // check alone allowed arbitrary/corrupt payloads to be treated as valid microphone audio.
        let validation = WAVEncoder.validateWAVHeader(wavData)
        guard validation.isValid,
              validation.sampleRate == UInt32(UnifiedAudioCapture.targetSampleRate),
              validation.channels == UInt16(UnifiedAudioCapture.targetChannelCount),
              validation.bitsPerSample == 16 else {
            throw SpeechModelEngineError.invalidAudioFormat(
                reason: validation.errorMessage ?? "Expected 16 kHz mono 16-bit PCM WAV audio."
            )
        }
        
        // Prepare audio content: in-memory or temporary file
        let audioContent: Content
        let tempAudioFileURL: URL?
        
        if useAudioFilePassing {
            // Write to temporary zero-copy scratch file
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EdgeEloquent/scratch", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
            try wavData.write(to: fileURL)
            tempAudioFileURL = fileURL
            audioContent = .audioFile(fileURL.path)
            logger.debug("Serialized audio to zero-copy temporary file: \(fileURL.path)")
        } else {
            tempAudioFileURL = nil
            audioContent = .audioData(wavData)
        }
        
        let textInstruction = prompt ?? Self.defaultTranscriptionPrompt
        
        // CRITICAL MULTIMODAL MESSAGE ORDERING RULE:
        // Google LiteRT-LM audio attention architecture mandates that the audio content node
        // must strictly PRECEDE the prompt text node in the serialized message:
        // [audioContent, textPrompt]
        let message = Message(
            contents: [
                audioContent,
                .text(textInstruction)
            ],
            role: .user
        )
        
        logger.info("Dispatched multimodal speech inference with \(wavData.count) audio bytes to \(self.modelInfo.name)")
        
        // Use the request/response conversation path for audio. This is the upstream path covered
        // by LiteRT-LM's functional transcription test; the token callback bridge is not required
        // for our already chunked microphone pipeline and could finish without yielding text.
        defer {
            if let tempURL = tempAudioFileURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        let response = try await conversation.sendMessage(
            message,
            maxOutputTokens: min(modelInfo.maxOutputTokens, 1_024)
        )
        let transcript = response.toString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw SpeechModelEngineError.transcriptionFailed(
                reason: "LiteRT-LM completed audio inference but returned no text."
            )
        }

        return AsyncThrowingStream { continuation in
            continuation.yield(transcript + " ")
            continuation.finish()
        }
    }
}
