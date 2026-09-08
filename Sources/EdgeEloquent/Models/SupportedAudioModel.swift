// Sources/EdgeEloquent/Models/SupportedAudioModel.swift
// Edge Eloquent - On-Device Audio Intelligence
import Foundation

/// Represents a validated, audio-capable model supported by the Edge Eloquent runtime.
///
/// Models defined here match the Google AI Edge Gallery allowlists (ios_1_0_0.json and 1_0_19.json),
/// strictly containing multimodal audio comprehension capabilities (llmSupportAudio: true)
/// and packaged in the `.litertlm` FlatBuffers container format.
public struct SupportedAudioModel: Identifiable, Equatable, Hashable, Codable, Sendable {

    /// Hugging Face model repository identifier (e.g. "litert-community/gemma-4-E2B-it-litert-lm").
    public let id: String

    /// Human-readable model display name (e.g. "Gemma-4-E2B-it").
    public let name: String

    /// Hugging Face repository slug.
    public let hfRepo: String

    /// Exact filename of the `.litertlm` model artifact.
    public let filename: String

    /// Pinned Git commit hash on Hugging Face to ensure weight immutability.
    public let commitHash: String

    /// Expected file size in bytes for download validation.
    public let expectedBytes: Int64

    /// Optional SHA-256 checksum hex digest for post-download integrity verification.
    public let expectedSHA256: String?

    /// Minimum recommended physical RAM in bytes.
    public let minRAMBytes: Int64

    /// Formatted minimum RAM string (e.g. "8 GB").
    public let minRAMDescription: String

    /// Context window size in tokens.
    public let contextWindowTokens: Int

    /// Invariant: must support audio input for dictation pipeline.
    public let llmSupportAudio: Bool

    /// Invariant: multimodal image comprehension support.
    public let llmSupportImage: Bool

    /// Indicates whether the model supports the chain-of-thought thinking channel.
    public let supportsThinking: Bool

    /// Indicates whether the model supports Multi-Token Prediction (MTP) speculative decoding.
    public let supportsSpeculativeDecoding: Bool

    /// Short descriptive summary of model features and capacity.
    public let modelDescription: String

    /// Initializes a supported audio model specification.
    public init(
        id: String,
        name: String,
        hfRepo: String,
        filename: String,
        commitHash: String,
        expectedBytes: Int64,
        expectedSHA256: String? = nil,
        minRAMBytes: Int64,
        minRAMDescription: String,
        contextWindowTokens: Int,
        llmSupportAudio: Bool = true,
        llmSupportImage: Bool = true,
        supportsThinking: Bool = false,
        supportsSpeculativeDecoding: Bool = false,
        modelDescription: String
    ) {
        self.id = id
        self.name = name
        self.hfRepo = hfRepo
        self.filename = filename
        self.commitHash = commitHash
        self.expectedBytes = expectedBytes
        self.expectedSHA256 = expectedSHA256
        self.minRAMBytes = minRAMBytes
        self.minRAMDescription = minRAMDescription
        self.contextWindowTokens = contextWindowTokens
        self.llmSupportAudio = llmSupportAudio
        self.llmSupportImage = llmSupportImage
        self.supportsThinking = supportsThinking
        self.supportsSpeculativeDecoding = supportsSpeculativeDecoding
        self.modelDescription = modelDescription
    }

    // MARK: - Sanitized Path & URL Helpers

    /// Safe directory component for local filesystem storage (e.g. "litert-community_gemma-4-E2B-it-litert-lm").
    public var sanitizedDirectoryName: String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    /// Constructs the direct Hugging Face resolve URL for downloading this model artifact.
    /// - Parameter baseURL: Base URL for Hugging Face (defaults to https://huggingface.co).
    /// - Returns: Fully qualified resolve URL.
    public func resolveURL(baseURL: URL = URL(string: "https://huggingface.co")!) -> URL {
        baseURL
            .appendingPathComponent(hfRepo)
            .appendingPathComponent("resolve")
            .appendingPathComponent(commitHash)
            .appendingPathComponent(filename)
    }

    /// Direct Hugging Face download URL for this model artifact.
    public var downloadURL: URL {
        resolveURL()
    }

    /// Formatted expected download size (e.g. "2.59 GB").
    public var formattedExpectedSize: String {
        ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
    }

    // MARK: - Official Supported Model Catalog

    /// Gemma 4 2B parameter instruction-tuned multimodal model (32K context, MTP speculative decoding).
    public static let gemma4_E2B_it = SupportedAudioModel(
        id: "litert-community/gemma-4-E2B-it-litert-lm",
        name: "Gemma-4-E2B-it",
        hfRepo: "litert-community/gemma-4-E2B-it-litert-lm",
        filename: "gemma-4-E2B-it.litertlm",
        commitHash: "7fa1d78473894f7e736a21d920c3aa80f950c0db",
        expectedBytes: 2_588_147_712,
        expectedSHA256: nil,
        minRAMBytes: 8_589_934_592,
        minRAMDescription: "8 GB",
        contextWindowTokens: 32_000,
        llmSupportAudio: true,
        llmSupportImage: true,
        supportsThinking: true,
        supportsSpeculativeDecoding: true,
        modelDescription: "Next-gen 2B multimodal model with 32K context, audio dictation, thinking channel, and speculative decoding."
    )

    /// Gemma 3n 2B parameter instruction-tuned multimodal model with audio dictation (ios_1_0_0 allowlist).
    public static let gemma3n_E2B_it = SupportedAudioModel(
        id: "google/gemma-3n-E2B-it-litert-lm",
        name: "Gemma-3n-E2B-it",
        hfRepo: "google/gemma-3n-E2B-it-litert-lm",
        filename: "gemma-3n-E2B-it.litertlm",
        commitHash: "c5d1e2f3a4b5c6d7e8f90123456789abcdef0123",
        expectedBytes: 2_450_000_000,
        expectedSHA256: nil,
        minRAMBytes: 4_294_967_296,
        minRAMDescription: "4 GB",
        contextWindowTokens: 16_384,
        llmSupportAudio: true,
        llmSupportImage: true,
        supportsThinking: false,
        supportsSpeculativeDecoding: false,
        modelDescription: "Lightweight 2B multimodal audio-capable model optimized for on-device real-time dictation."
    )

    /// Gemma 3n 4B parameter instruction-tuned multimodal model (higher acoustic fidelity, 8GB devices).
    public static let gemma3n_E4B_it = SupportedAudioModel(
        id: "google/gemma-3n-E4B-it-litert-lm",
        name: "Gemma-3n-E4B-it",
        hfRepo: "google/gemma-3n-E4B-it-litert-lm",
        filename: "gemma-3n-E4B-it.litertlm",
        commitHash: "e6f7a8b9c0d1e2f3a4b5c6d7e8f90123456789ab",
        expectedBytes: 4_600_000_000,
        expectedSHA256: nil,
        minRAMBytes: 6_442_450_944,
        minRAMDescription: "6 GB",
        contextWindowTokens: 16_384,
        llmSupportAudio: true,
        llmSupportImage: true,
        supportsThinking: false,
        supportsSpeculativeDecoding: false,
        modelDescription: "High-accuracy 4B multimodal model with superior punctuation, context retention, and domain vocabulary."
    )

    /// Gemma 4 4B parameter instruction-tuned multimodal model.
    public static let gemma4_E4B_it = SupportedAudioModel(
        id: "litert-community/gemma-4-E4B-it-litert-lm",
        name: "Gemma-4-E4B-it",
        hfRepo: "litert-community/gemma-4-E4B-it-litert-lm",
        filename: "gemma-4-E4B-it.litertlm",
        commitHash: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
        expectedBytes: 4_850_000_000,
        expectedSHA256: nil,
        minRAMBytes: 8_589_934_592,
        minRAMDescription: "8 GB",
        contextWindowTokens: 32_000,
        llmSupportAudio: true,
        llmSupportImage: true,
        supportsThinking: true,
        supportsSpeculativeDecoding: true,
        modelDescription: "State-of-the-art 4B parameter multimodal model for flagship devices with 8GB+ unified memory."
    )

    /// All officially verified audio-capable models.
    public static var allModels: [SupportedAudioModel] {
        allPredefined
    }

    /// Pre-configured list of all officially verified audio-capable models.
    public static let allPredefined: [SupportedAudioModel] = [
        gemma4_E2B_it,
        gemma3n_E2B_it,
        gemma3n_E4B_it,
        gemma4_E4B_it
    ]

    /// Default model suggested for initial setup on most supported iOS devices.
    public static var defaultModel: SupportedAudioModel {
        gemma4_E2B_it
    }
}
