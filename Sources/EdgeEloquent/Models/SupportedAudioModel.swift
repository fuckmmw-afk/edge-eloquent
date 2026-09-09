// Sources/EdgeEloquent/Models/SupportedAudioModel.swift
// Edge Eloquent - On-Device Audio Intelligence
import Foundation

/// Represents a validated, audio-capable model supported by the Edge Eloquent runtime.
///
/// Built-in models are pinned, audio-capable `.litertlm` artifacts. Additional
/// compatible artifacts can be discovered through Hugging Face at runtime.
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

    // MARK: - Built-In Supported Model Catalog

    /// Compact multilingual ASR model for memory-constrained phones. Unlike the
    /// multimodal Gemma models, this bundle is dedicated to five-second speech windows.
    public static let qwen3ASR_06B = SupportedAudioModel(
        id: "litert-community/Qwen3-ASR-0.6B",
        name: "Qwen3-ASR-0.6B",
        hfRepo: "litert-community/Qwen3-ASR-0.6B",
        filename: "qwen3_asr_0.6b_5s_i8.litertlm",
        commitHash: "80384dfbad4a6cd0c698892395c4664fd122c081",
        expectedBytes: 959_627_232,
        expectedSHA256: "d4444d51f0c08142f57e16097673150f3ea02900a00b29a58a41f6e7578db251",
        minRAMBytes: 4_294_967_296,
        minRAMDescription: "4 GB",
        contextWindowTokens: 1_024,
        llmSupportAudio: true,
        llmSupportImage: false,
        modelDescription: "Compact 5-second-window ASR model with Russian and 29 other languages; recommended for iPhone 12."
    )

    /// BitNet speech recognizer matching the approximately 1.87 GiB model exposed by
    /// Google AI Edge Gallery's Hugging Face model discovery flow.
    public static let vibeVoiceASRBitNet = SupportedAudioModel(
        id: "litert-community/VibeVoice-ASR-BitNet",
        name: "VibeVoice-ASR-BitNet",
        hfRepo: "litert-community/VibeVoice-ASR-BitNet",
        filename: "VibeVoice-ASR-BitNet.litertlm",
        commitHash: "4c72febccd72b2fc40eaad28275353d4cdb9166d",
        expectedBytes: 1_983_019_248,
        expectedSHA256: "5ca907b0343d3e6bd9ec3dbf8aecbcc99b733633ef007a78a7e0f3502010af1b",
        minRAMBytes: 4_294_967_296,
        minRAMDescription: "4 GB",
        contextWindowTokens: 2_048,
        llmSupportAudio: true,
        llmSupportImage: false,
        modelDescription: "Efficient BitNet ASR (~1.85 GiB) for English, Chinese, French, Italian, Korean, Portuguese, and Vietnamese."
    )

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
        minRAMBytes: 6_442_450_944,
        minRAMDescription: "6 GB",
        contextWindowTokens: 4_096,
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
        minRAMBytes: 8_589_934_592,
        minRAMDescription: "8 GB",
        contextWindowTokens: 4_096,
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

    /// Built-in pinned models plus legacy Gemma migration entries.
    public static var allModels: [SupportedAudioModel] {
        allPredefined
    }

    /// Pre-configured list of pinned audio-capable models.
    public static let allPredefined: [SupportedAudioModel] = [
        qwen3ASR_06B,
        vibeVoiceASRBitNet,
        gemma3n_E2B_it,
        gemma3n_E4B_it
    ]

    /// Default model suggested for initial setup on most supported iOS devices.
    public static var defaultModel: SupportedAudioModel {
        qwen3ASR_06B
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

    /// Converts verified Hugging Face metadata into a persistable downloadable model.
    public init?(compatibilityReport report: ModelCompatibilityReport) {
        guard report.isCompatible,
              let filename = report.modelFilename,
              let expectedBytes = report.fileSizeBytes,
              expectedBytes > 0,
              let revision = report.commitHash,
              !revision.isEmpty else {
            return nil
        }

        let estimatedRAMGb: Int64
        switch expectedBytes {
        case ...2_100_000_000: estimatedRAMGb = 4
        case ...3_700_000_000: estimatedRAMGb = 6
        default: estimatedRAMGb = 8
        }

        self.init(
            id: report.modelId,
            name: report.modelId.split(separator: "/").last.map(String.init) ?? report.modelId,
            hfRepo: report.modelId,
            filename: filename,
            commitHash: revision,
            expectedBytes: expectedBytes,
            expectedSHA256: report.artifactSHA256,
            minRAMBytes: estimatedRAMGb * 1_073_741_824,
            minRAMDescription: "\(estimatedRAMGb) GB estimated",
            contextWindowTokens: 1_024,
            llmSupportAudio: true,
            llmSupportImage: false,
            modelDescription: "Audio-capable LiteRT-LM model imported from Hugging Face. Compatibility is based on repository metadata."
        )
    }
}
