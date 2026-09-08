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
        expectedBytes: 2_583_085_056,
        expectedSHA256: "ab7838cdfc8f77e54d8ca45eadceb20452d9f01e4bfade03e5dce27911b27e42",
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
        filename: "gemma-3n-E2B-it-int4.litertlm",
        commitHash: "c03b6f60b8da6c5400b6838a2cf26420f80c0a01",
        expectedBytes: 3_655_827_456,
        expectedSHA256: "2ed7bc3a0026c93d5b8a4544b352d9d00cd66ff0bac3ef6a20ac3d2cba4010d6",
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
        filename: "gemma-3n-E4B-it-int4.litertlm",
        commitHash: "297ed75955702dec3503e00c2c2ecbbf475300bc",
        expectedBytes: 4_919_541_760,
        expectedSHA256: "2e67a6cd51dfe0f793431e6bd4ed8d029c88e10f52ca0469ad38445e3cd3c1f4",
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
        commitHash: "2eee7ac325f20eb8c9ac1d0e972f7c84663062da",
        expectedBytes: 3_659_530_240,
        expectedSHA256: "0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0",
        minRAMBytes: 8_589_934_592,
        minRAMDescription: "8 GB",
        contextWindowTokens: 32_000,
        llmSupportAudio: true,
        llmSupportImage: true,
        supportsThinking: true,
        supportsSpeculativeDecoding: true,
        modelDescription: "State-of-the-art 4B parameter multimodal model for flagship devices with 8GB+ unified memory."
    )

    /// Models publicly validated for the iOS LiteRT-LM path.
    public static var allModels: [SupportedAudioModel] {
        allPredefined
    }

    /// Pre-configured list of all officially verified audio-capable models.
    public static let allPredefined: [SupportedAudioModel] = [
        gemma3n_E2B_it,
        gemma3n_E4B_it
    ]

    /// Default model suggested for initial setup on most supported iOS devices.
    public static var defaultModel: SupportedAudioModel {
        gemma3n_E2B_it
    }

    /// Searches predefined models by id, name, or repository slug.
    public static func find(byIdOrName query: String) -> SupportedAudioModel? {
        let q = query.lowercased()
        return allPredefined.first { model in
            model.id.lowercased() == q ||
            model.name.lowercased() == q ||
            model.hfRepo.lowercased() == q ||
            model.filename.lowercased() == q
        }
    }
}
