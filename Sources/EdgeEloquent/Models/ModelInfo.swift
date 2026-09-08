//
//  ModelInfo.swift
//  EdgeEloquent
//
//  Created by ModelAgent on 2026-09-08.
//

import Foundation

/// Defines hardware accelerators assigned to model subgraphs.
public struct ModelAccelerators: Sendable, Codable, Hashable, Equatable {
    public enum Accelerator: String, Sendable, Codable, Hashable {
        case gpu
        case cpu
        case neuralEngine
    }
    
    /// Target accelerator for primary autoregressive LLM decoding (Metal MSL on Apple Silicon).
    public let llm: Accelerator
    
    /// Target accelerator for acoustic feature extraction and Conformer projector (ARM NEON on CPU).
    public let audio: Accelerator
    
    /// Optional target accelerator for visual encoder (SigLIP / ViT on GPU).
    public let vision: Accelerator?
    
    public init(
        llm: Accelerator = .gpu,
        audio: Accelerator = .cpu,
        vision: Accelerator? = .gpu
    ) {
        self.llm = llm
        self.audio = audio
        self.vision = vision
    }
}

/// Distinct machine learning task types supported by edge models matching upstream allowlists.
public enum ModelTaskType: String, Sendable, Codable, Hashable, CaseIterable {
    case askAudio = "llm_ask_audio"
    case chat = "llm_chat"
    case askImage = "llm_ask_image"
    case transcription = "transcription"
    case thinking = "llm_thinking"
}

/// Metadata, hardware specifications, and capabilities for an on-device model.
/// Strictly excludes weights from the application bundle; models are downloaded on-demand from Hugging Face.
public struct ModelInfo: Identifiable, Sendable, Codable, Hashable, Equatable {
    /// Unique identifier for the model entry.
    public let id: String
    
    /// Human-readable model display name.
    public let name: String
    
    /// Hugging Face Hub repository identifier (e.g. "litert-community/gemma-4-E2B-it-litert-lm").
    public let modelId: String
    
    /// Target artifact filename within the Hugging Face repository (must end in `.litertlm` for LiteRT models).
    public let modelFile: String
    
    /// Total binary size of the model artifact in bytes.
    public let sizeInBytes: Int64
    
    /// Minimum physical device RAM required in gigabytes to run without triggering iOS Jetsam limits.
    public let minDeviceMemoryInGb: Int
    
    /// Git commit SHA-256 hash pinned for download integrity verification and cache busting.
    public let commitHash: String
    
    /// Accelerator allocation for LLM, audio, and vision subgraphs.
    public let accelerators: ModelAccelerators
    
    /// Supported operational tasks (e.g. `llm_ask_audio`, `llm_chat`).
    public let taskTypes: [ModelTaskType]
    
    /// Maximum context window in tokens (prompt + audio tokens + generated response).
    public let maxContextTokens: Int
    
    /// Maximum generation token budget.
    public let maxOutputTokens: Int
    
    /// Whether the model natively accepts and comprehends audio PCM waveforms.
    public let supportsAudio: Bool
    
    /// Whether the model natively accepts visual input frames.
    public let supportsVision: Bool
    
    /// Whether the model supports Multi-Token Prediction (MTP) / speculative decoding.
    public let supportsSpeculativeDecoding: Bool
    
    /// Whether the model features an internal chain-of-thought thinking channel.
    public let supportsThinking: Bool
    
    /// True for platform-embedded speech engines (e.g. Apple SFSpeechRecognizer) requiring 0 download bytes.
    public let isSystemProvided: Bool
    
    public init(
        id: String,
        name: String,
        modelId: String,
        modelFile: String,
        sizeInBytes: Int64,
        minDeviceMemoryInGb: Int,
        commitHash: String,
        accelerators: ModelAccelerators,
        taskTypes: [ModelTaskType],
        maxContextTokens: Int,
        maxOutputTokens: Int = 4096,
        supportsAudio: Bool = true,
        supportsVision: Bool = false,
        supportsSpeculativeDecoding: Bool = false,
        supportsThinking: Bool = false,
        isSystemProvided: Bool = false
    ) {
        self.id = id
        self.name = name
        self.modelId = modelId
        self.modelFile = modelFile
        self.sizeInBytes = sizeInBytes
        self.minDeviceMemoryInGb = minDeviceMemoryInGb
        self.commitHash = commitHash
        self.accelerators = accelerators
        self.taskTypes = taskTypes
        self.maxContextTokens = maxContextTokens
        self.maxOutputTokens = maxOutputTokens
        self.supportsAudio = supportsAudio
        self.supportsVision = supportsVision
        self.supportsSpeculativeDecoding = supportsSpeculativeDecoding
        self.supportsThinking = supportsThinking
        self.isSystemProvided = isSystemProvided
    }
}

// MARK: - Computed Properties & Helpers

extension ModelInfo {
    /// Formatted human-readable file size (e.g. "2.59 GB").
    public var formattedSize: String {
        if isSystemProvided || sizeInBytes == 0 {
            return "0 MB (Built-in)"
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeInBytes)
    }
    
    /// Direct immutable CDN download URL on Hugging Face Hub pinned to the verified commit hash.
    public var downloadURL: URL? {
        guard !isSystemProvided else { return nil }
        return URL(string: "https://huggingface.co/\(modelId)/resolve/\(commitHash)/\(modelFile)?download=true")
    }
    
    /// Web page URL for inspecting the repository and accepting gated model terms on Hugging Face Hub.
    public var huggingFaceWebURL: URL? {
        guard !isSystemProvided else { return nil }
        return URL(string: "https://huggingface.co/\(modelId)")
    }
    
    /// Relative local storage path inside Application Support directory.
    public var localRelativePath: String {
        guard !isSystemProvided else { return "system/speech" }
        let safeModelId = modelId.replacingOccurrences(of: "/", with: "_")
        return "models/\(safeModelId)/\(commitHash)/\(modelFile)"
    }

    /// Whether the model binary is already locally cached.
    public var isLocallyCached: Bool {
        guard !isSystemProvided else { return false }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let target = appSupport?.appendingPathComponent(localRelativePath)
        return target.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
    
    /// Checks if a device with the given physical memory satisfies the model's memory requirements.
    public func isDeviceCompatible(deviceMemoryInGb: Int) -> Bool {
        deviceMemoryInGb >= minDeviceMemoryInGb
    }
}

// MARK: - Official Factory Presets (Google AI Edge Gallery Allowlists)

extension ModelInfo {
    /// Gemma 4 E2B-it (LiteRT-LM): Next-generation multimodal audio model featuring 32K context and speculative decoding.
    /// Default recommended model for modern 8 GB Apple Silicon devices (iPhone 15 Pro, iPhone 16 / 16 Pro).
    public static let gemma4_E2B = ModelInfo(
        id: "gemma-4-e2b-it",
        name: "Gemma-4-E2B-it",
        modelId: "litert-community/gemma-4-E2B-it-litert-lm",
        modelFile: "gemma-4-E2B-it.litertlm",
        sizeInBytes: 2_588_147_712, // ~2.59 GB
        minDeviceMemoryInGb: 8,
        commitHash: "6e5c4f1e395deb959c494953478fa5cec4b8008f",
        accelerators: ModelAccelerators(llm: .gpu, audio: .cpu, vision: .gpu),
        taskTypes: [.askAudio, .chat, .transcription, .thinking],
        maxContextTokens: 32_000,
        maxOutputTokens: 4_000,
        supportsAudio: true,
        supportsVision: true,
        supportsSpeculativeDecoding: true,
        supportsThinking: true,
        isSystemProvided: false
    )
    
    /// Gemma 4 E4B-it (LiteRT-LM): High-capacity multimodal model with superior reasoning and acoustic comprehension.
    /// Recommended for 12 GB+ devices (iPhone 16 Pro Max, M-series iPads/Macs).
    public static let gemma4_E4B = ModelInfo(
        id: "gemma-4-e4b-it",
        name: "Gemma-4-E4B-it",
        modelId: "litert-community/gemma-4-E4B-it-litert-lm",
        modelFile: "gemma-4-E4B-it.litertlm",
        sizeInBytes: 3_659_530_240, // ~3.66 GB
        minDeviceMemoryInGb: 12,
        commitHash: "28299f30ee4d43294517a4ac93abd6163412f07f",
        accelerators: ModelAccelerators(llm: .gpu, audio: .cpu, vision: .gpu),
        taskTypes: [.askAudio, .chat, .transcription, .thinking],
        maxContextTokens: 32_000,
        maxOutputTokens: 4_000,
        supportsAudio: true,
        supportsVision: true,
        supportsSpeculativeDecoding: true,
        supportsThinking: true,
        isSystemProvided: false
    )
    
    /// Gemma 3n E2B-it (LiteRT-LM): The official baseline audio-capable model certified in iOS allowlist `ios_1_0_0.json`.
    /// Operates comfortably on 6 GB and 8 GB Apple Silicon devices.
    public static let gemma3n_E2B = ModelInfo(
        id: "gemma-3n-e2b-it",
        name: "Gemma-3n-E2B-it",
        modelId: "google/gemma-3n-E2B-it-litert-lm",
        modelFile: "gemma-3n-E2B-it-int4.litertlm",
        sizeInBytes: 3_388_604_416, // ~3.39 GB
        minDeviceMemoryInGb: 6,
        commitHash: "73b019b63436d346f68dd9c1dbfd117eb264d888",
        accelerators: ModelAccelerators(llm: .gpu, audio: .cpu, vision: .gpu),
        taskTypes: [.askAudio, .chat, .transcription],
        maxContextTokens: 4_096,
        maxOutputTokens: 4_096,
        supportsAudio: true,
        supportsVision: true,
        supportsSpeculativeDecoding: false,
        supportsThinking: false,
        isSystemProvided: false
    )
    
    /// Gemma 3n E4B-it (LiteRT-LM): Extended 4B parameter model from `ios_1_0_0.json` allowlist.
    /// High-fidelity transcription requiring minimum 8 GB RAM.
    public static let gemma3n_E4B = ModelInfo(
        id: "gemma-3n-e4b-it",
        name: "Gemma-3n-E4B-it",
        modelId: "google/gemma-3n-E4B-it-litert-lm",
        modelFile: "gemma-3n-E4B-it-int4.litertlm",
        sizeInBytes: 4_652_318_720, // ~4.65 GB
        minDeviceMemoryInGb: 8,
        commitHash: "3d0179a0648381585ab337e170b7517aae8e0ce4",
        accelerators: ModelAccelerators(llm: .gpu, audio: .cpu, vision: .gpu),
        taskTypes: [.askAudio, .chat, .transcription],
        maxContextTokens: 4_096,
        maxOutputTokens: 4_096,
        supportsAudio: true,
        supportsVision: true,
        supportsSpeculativeDecoding: false,
        supportsThinking: false,
        isSystemProvided: false
    )
    
    /// Apple Native On-Device Speech Recognizer (SFSpeechRecognizer).
    /// Zero-download baseline fallback requiring 0 bytes download and minimal memory.
    public static let appleNative = ModelInfo(
        id: "apple-native-speech",
        name: "Apple Native Speech",
        modelId: "apple/on-device-speech",
        modelFile: "system-embedded",
        sizeInBytes: 0,
        minDeviceMemoryInGb: 4,
        commitHash: "system",
        accelerators: ModelAccelerators(llm: .neuralEngine, audio: .neuralEngine, vision: nil),
        taskTypes: [.transcription, .askAudio],
        maxContextTokens: 4_096,
        maxOutputTokens: 4_096,
        supportsAudio: true,
        supportsVision: false,
        supportsSpeculativeDecoding: false,
        supportsThinking: false,
        isSystemProvided: true
    )
    
    /// All audio-capable LiteRT-LM models from Google AI Edge Gallery allowlists.
    public static let allLiteRTAudioModels: [ModelInfo] = [
        gemma4_E2B,
        gemma4_E4B,
        gemma3n_E2B,
        gemma3n_E4B
    ]
    
    /// Complete catalog of all supported speech models including the native iOS fallback.
    public static let allSupportedModels: [ModelInfo] = [
        gemma4_E2B,
        gemma4_E4B,
        gemma3n_E2B,
        gemma3n_E4B,
        appleNative
    ]
    
    /// Default active model preset (Gemma 4 E2B-it).
    public static let defaultModel: ModelInfo = gemma4_E2B
}

// MARK: - SupportedAudioModel Interoperability

extension ModelInfo {
    /// Creates a `ModelInfo` from a `SupportedAudioModel`.
    public init(supportedModel: SupportedAudioModel) {
        let taskTypes: [ModelTaskType] = [
            .askAudio,
            .chat,
            .transcription,
            supportedModel.supportsThinking ? .thinking : nil
        ].compactMap { $0 }
        
        self.init(
            id: supportedModel.id,
            name: supportedModel.name,
            modelId: supportedModel.hfRepo,
            modelFile: supportedModel.filename,
            sizeInBytes: supportedModel.expectedBytes,
            minDeviceMemoryInGb: Int(supportedModel.minRAMBytes / (1024 * 1024 * 1024)),
            commitHash: supportedModel.commitHash,
            accelerators: ModelAccelerators(llm: .gpu, audio: .cpu, vision: supportedModel.llmSupportImage ? .gpu : nil),
            taskTypes: taskTypes,
            maxContextTokens: supportedModel.contextWindowTokens,
            maxOutputTokens: 4_000,
            supportsAudio: supportedModel.llmSupportAudio,
            supportsVision: supportedModel.llmSupportImage,
            supportsSpeculativeDecoding: supportedModel.supportsSpeculativeDecoding,
            supportsThinking: supportedModel.supportsThinking,
            isSystemProvided: false
        )
    }
}

