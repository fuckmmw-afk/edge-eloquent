//
//  SpeechModelEngine.swift
//  EdgeEloquent
//
//  Created by ModelAgent on 2026-09-08.
//

import Foundation

/// Comprehensive error definitions encountered during speech engine lifecycle and transcription.
public enum SpeechModelEngineError: LocalizedError, Sendable, Equatable {
    case modelFileNotFound(path: String)
    case modelNotLoaded
    case alreadyLoaded
    case engineInitializationFailed(reason: String)
    case transcriptionFailed(reason: String)
    case invalidAudioFormat(reason: String)
    case insufficientDeviceMemory(requiredGb: Int, availableGb: Int)
    case cancelled
    case speechRecognitionUnavailable
    case speechRecognitionPermissionDenied
    case runtimeUnavailable
    
    public var errorDescription: String? {
        switch self {
        case .modelFileNotFound(let path):
            return "Model weights file not found on disk at path: \(path)"
        case .modelNotLoaded:
            return "Speech model engine is not loaded. Call load() prior to transcription."
        case .alreadyLoaded:
            return "Speech model engine is already loaded."
        case .engineInitializationFailed(let reason):
            return "Failed to initialize speech engine: \(reason)"
        case .transcriptionFailed(let reason):
            return "Speech transcription failed: \(reason)"
        case .invalidAudioFormat(let reason):
            return "Invalid audio input format: \(reason)"
        case .insufficientDeviceMemory(let requiredGb, let availableGb):
            return "Insufficient device RAM. Model requires \(requiredGb) GB, but device has \(availableGb) GB."
        case .cancelled:
            return "Transcription operation was cancelled."
        case .speechRecognitionUnavailable:
            return "Apple native speech recognition service is currently unavailable."
        case .speechRecognitionPermissionDenied:
            return "Speech recognition authorization was denied by the user."
        case .runtimeUnavailable:
            return "LiteRT-LM runtime is unavailable in this build."
        }
    }
}

/// Abstract protocol for all speech comprehension engines.
/// Decouples higher-level coordinators and UI from specific runtime implementations (LiteRT-LM vs. Apple Native).
public protocol SpeechModelEngine: AnyObject, Sendable {
    /// Associated model metadata, hardware requirements, and capabilities.
    var modelInfo: ModelInfo { get }
    
    /// Whether the model weights are currently memory-mapped and runtime pipelines compiled.
    var isLoaded: Bool { get }
    
    /// Asynchronously loads model weights into memory and compiles hardware acceleration pipelines.
    func load() async throws
    
    /// Unloads weights from memory, releases Metal pipelines, and allows kernel page reclamation.
    func unload() async
    
    /// Transcribes an in-memory 16kHz Linear PCM RIFF WAV audio buffer into streaming text tokens.
    ///
    /// - Parameters:
    ///   - wavData: Byte buffer containing 16kHz mono 16-bit Linear PCM audio packaged with standard RIFF WAV header.
    ///   - prompt: Optional task instructions or context conditioning (e.g. system instructions, formatting guidelines).
    /// - Returns: An asynchronous throwing stream yielding partial/incremental text tokens as they are decoded.
    func transcribeAudio(wavData: Data, prompt: String?) async throws -> AsyncThrowingStream<String, Error>
}

extension SpeechModelEngine {
    /// Canonical system prompt for speech transcription ensuring deterministic output without LLM conversational chattiness.
    public static var defaultTranscriptionPrompt: String {
        "Transcribe the speech accurately with punctuation. Return only the recognized text."
    }
}
