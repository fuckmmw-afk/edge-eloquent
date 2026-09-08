// Sources/EdgeEloquent/Models/HuggingFaceSearchService.swift
// Edge Eloquent - On-Device Audio Intelligence
import Foundation

// MARK: - Hugging Face API Models

/// Sibling file artifact listed inside a Hugging Face repository.
public struct HuggingFaceSibling: Codable, Equatable, Hashable, Sendable {
    /// Relative filename (e.g. "gemma-4-E2B-it.litertlm").
    public let rfilename: String

    /// File size in bytes if available.
    public let size: Int64?

    /// Git LFS metadata pointer if tracked via LFS.
    public let lfs: HuggingFaceLFS?

    public init(rfilename: String, size: Int64? = nil, lfs: HuggingFaceLFS? = nil) {
        self.rfilename = rfilename
        self.size = size
        self.lfs = lfs
    }

    /// Effective size in bytes (prefers LFS size if available).
    public var resolvedSize: Int64? {
        lfs?.size ?? size
    }

    /// Whether this file is a LiteRT-LM binary container artifact.
    public var isLitertlm: Bool {
        rfilename.lowercased().hasSuffix(".litertlm")
    }
}

/// Git LFS metadata from Hugging Face API.
public struct HuggingFaceLFS: Codable, Equatable, Hashable, Sendable {
    /// Git LFS Object Identifier (SHA-256 commit hash).
    public let oid: String?

    /// File size in bytes.
    public let size: Int64?

    public init(oid: String?, size: Int64?) {
        self.oid = oid
        self.size = size
    }
}

/// Card metadata containing model capabilities.
public struct HuggingFaceCardData: Codable, Equatable, Sendable {
    public let tags: [String]?
    public let llmSupportAudio: Bool?
    public let llmSupportImage: Bool?

    enum CodingKeys: String, CodingKey {
        case tags
        case llmSupportAudio = "llmSupportAudio"
        case llmSupportImage = "llmSupportImage"
    }

    public init(
        tags: [String]? = nil,
        llmSupportAudio: Bool? = nil,
        llmSupportImage: Bool? = nil
    ) {
        self.tags = tags
        self.llmSupportAudio = llmSupportAudio
        self.llmSupportImage = llmSupportImage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags)

        // Decode boolean or string representation for llmSupportAudio
        if let boolVal = try? container.decodeIfPresent(Bool.self, forKey: .llmSupportAudio) {
            self.llmSupportAudio = boolVal
        } else if let strVal = try? container.decodeIfPresent(String.self, forKey: .llmSupportAudio) {
            self.llmSupportAudio = (strVal.lowercased() == "true")
        } else {
            self.llmSupportAudio = nil
        }

        if let boolVal = try? container.decodeIfPresent(Bool.self, forKey: .llmSupportImage) {
            self.llmSupportImage = boolVal
        } else if let strVal = try? container.decodeIfPresent(String.self, forKey: .llmSupportImage) {
            self.llmSupportImage = (strVal.lowercased() == "true")
        } else {
            self.llmSupportImage = nil
        }
    }
}

/// Metadata payload returned by `https://huggingface.co/api/models/{modelId}`.
public struct HuggingFaceModelMetadata: Codable, Equatable, Sendable {
    /// Model identifier (e.g. "litert-community/gemma-4-E2B-it-litert-lm").
    public let id: String

    /// Author or organization (e.g. "litert-community", "google").
    public let author: String?

    /// Commit SHA for repository state.
    public let sha: String?

    /// Repository tags.
    public let tags: [String]

    /// Pipeline category tag (e.g. "automatic-speech-recognition", "audio-to-text").
    public let pipelineTag: String?

    /// List of file artifacts in repository.
    public let siblings: [HuggingFaceSibling]

    /// Model card metadata.
    public let cardData: HuggingFaceCardData?

    enum CodingKeys: String, CodingKey {
        case id
        case author
        case sha
        case tags
        case pipelineTag = "pipeline_tag"
        case siblings
        case cardData
    }

    public init(
        id: String,
        author: String? = nil,
        sha: String? = nil,
        tags: [String] = [],
        pipelineTag: String? = nil,
        siblings: [HuggingFaceSibling] = [],
        cardData: HuggingFaceCardData? = nil
    ) {
        self.id = id
        self.author = author
        self.sha = sha
        self.tags = tags
        self.pipelineTag = pipelineTag
        self.siblings = siblings
        self.cardData = cardData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.author = try container.decodeIfPresent(String.self, forKey: .author)
        self.sha = try container.decodeIfPresent(String.self, forKey: .sha)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.pipelineTag = try container.decodeIfPresent(String.self, forKey: .pipelineTag)
        self.siblings = try container.decodeIfPresent([HuggingFaceSibling].self, forKey: .siblings) ?? []
        self.cardData = try container.decodeIfPresent(HuggingFaceCardData.self, forKey: .cardData)
    }

    /// All `.litertlm` container files present in the repository.
    public var litertlmSiblings: [HuggingFaceSibling] {
        siblings.filter { $0.isLitertlm }
    }

    /// Primary `.litertlm` artifact.
    public var primaryLitertlmSibling: HuggingFaceSibling? {
        litertlmSiblings.first
    }
}

// MARK: - Verification & Compatibility Results

/// Verification assessment confirming whether a Hugging Face repository is compatible
/// with the Edge Eloquent on-device audio dictation pipeline.
public struct ModelCompatibilityReport: Equatable, Sendable {
    /// Hugging Face repository ID.
    public let modelId: String

    /// Master compatibility boolean.
    public let isCompatible: Bool

    /// Whether repository contains a valid `.litertlm` format container.
    public let hasLitertlmFormat: Bool

    /// Whether model meets Google AI Edge Gallery audio criteria (`llmSupportAudio: true`).
    public let supportsAudio: Bool

    /// Name of the verified `.litertlm` model artifact file.
    public let modelFilename: String?

    /// Expected file size in bytes.
    public let fileSizeBytes: Int64?

    /// Commit hash / Git LFS OID.
    public let commitHash: String?

    /// Detailed diagnostic reasons for compatibility verdict.
    public let diagnosticReasons: [String]

    public init(
        modelId: String,
        isCompatible: Bool,
        hasLitertlmFormat: Bool,
        supportsAudio: Bool,
        modelFilename: String?,
        fileSizeBytes: Int64?,
        commitHash: String?,
        diagnosticReasons: [String]
    ) {
        self.modelId = modelId
        self.isCompatible = isCompatible
        self.hasLitertlmFormat = hasLitertlmFormat
        self.supportsAudio = supportsAudio
        self.modelFilename = modelFilename
        self.fileSizeBytes = fileSizeBytes
        self.commitHash = commitHash
        self.diagnosticReasons = diagnosticReasons
    }
}

/// Errors occurring during Hugging Face API queries or model verification.
public enum HuggingFaceServiceError: LocalizedError, Equatable {
    case invalidURL(String)
    case invalidResponse(statusCode: Int, message: String)
    case authenticationRequired(modelId: String)
    case decodingError(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let str):
            return "Invalid Hugging Face API URL: \(str)"
        case .invalidResponse(let code, let msg):
            return "Hugging Face API returned HTTP \(code): \(msg)"
        case .authenticationRequired(let id):
            return "Access to gated model '\(id)' requires a valid Hugging Face Bearer Token."
        case .decodingError(let detail):
            return "Failed to decode Hugging Face metadata: \(detail)"
        case .networkError(let detail):
            return "Network connection error: \(detail)"
        }
    }
}

// MARK: - Service Implementation

/// Service responsible for querying Hugging Face Hub metadata and validating
/// model compatibility against Google AI Edge Gallery audio dictation criteria.
public final class HuggingFaceSearchService: Sendable {

    public let session: URLSession
    public let baseURL: URL

    /// Initializes a new Hugging Face search service.
    /// - Parameters:
    ///   - session: URLSession for network requests (can be mocked for testing).
    ///   - baseURL: Base URL for Hugging Face Hub (defaults to https://huggingface.co).
    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://huggingface.co")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: - API Queries

    /// Queries `https://huggingface.co/api/models/{modelId}` with blob expansion.
    /// - Parameters:
    ///   - modelId: Hugging Face model repository ID.
    ///   - bearerToken: Optional Hugging Face user access token.
    /// - Returns: Decoded metadata for the model repository.
    public func fetchModelMetadata(
        modelId: String,
        bearerToken: String? = nil
    ) async throws -> HuggingFaceModelMetadata {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("api/models/\(modelId)"), resolvingAgainstBaseURL: true) else {
            throw HuggingFaceServiceError.invalidURL(modelId)
        }
        components.queryItems = [
            URLQueryItem(name: "blobs", value: "true")
        ]

        guard let requestURL = components.url else {
            throw HuggingFaceServiceError.invalidURL(modelId)
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIEdgeGallery/1.0 (iOS) EdgeEloquent/1.0", forHTTPHeaderField: "User-Agent")

        if let token = bearerToken, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HuggingFaceServiceError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HuggingFaceServiceError.invalidResponse(statusCode: 0, message: "Non-HTTP response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw HuggingFaceServiceError.authenticationRequired(modelId: modelId)
        }

        guard httpResponse.statusCode == 200 else {
            let msg = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw HuggingFaceServiceError.invalidResponse(statusCode: httpResponse.statusCode, message: msg)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(HuggingFaceModelMetadata.self, from: data)
        } catch {
            throw HuggingFaceServiceError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Compatibility Verification

    /// Verifies model compatibility for the Edge Eloquent on-device audio dictation pipeline.
    ///
    /// Rules derived from Google AI Edge Gallery allowlist criteria:
    /// 1. **Format Invariant:** Must have a `.litertlm` artifact.
    /// 2. **Audio Dictation Invariant:**
    ///    - Explicitly sets `llmSupportAudio: true` in cardData/config, OR
    ///    - Contains audio tags ("audio", "speech", "llm_ask_audio"), OR
    ///    - Matches the known official audio allowlist (Gemma-4-E2B, Gemma-4-E4B, Gemma-3n-E2B, Gemma-3n-E4B).
    public func verifyCompatibility(metadata: HuggingFaceModelMetadata) -> ModelCompatibilityReport {
        var reasons: [String] = []

        // 1. Format verification (.litertlm)
        let litertlmFiles = metadata.litertlmSiblings
        let hasLitertlm = !litertlmFiles.isEmpty
        if !hasLitertlm {
            reasons.append("Repository lacks a .litertlm LiteRT-LM binary artifact.")
        }

        // 2. Audio capability verification
        let cardSupportsAudio = (metadata.cardData?.llmSupportAudio == true)

        let audioTags = ["audio", "speech", "llm_ask_audio", "voice", "audio-to-text", "speech-recognition"]
        let lowerTags = metadata.tags.map { $0.lowercased() }
        let tagsSupportAudio = lowerTags.contains { tag in
            audioTags.contains { tag.contains($0) }
        }

        let pipelineSupportsAudio = metadata.pipelineTag == "automatic-speech-recognition" ||
                                    metadata.pipelineTag == "audio-to-text"

        let isOfficialAudioModel = SupportedAudioModel.allModels.contains { model in
            model.id.caseInsensitiveCompare(metadata.id) == .orderedSame ||
            model.hfRepo.caseInsensitiveCompare(metadata.id) == .orderedSame
        }

        let supportsAudio = cardSupportsAudio || tagsSupportAudio || pipelineSupportsAudio || isOfficialAudioModel

        if !supportsAudio {
            reasons.append("Model does not indicate audio/speech dictation support (llmSupportAudio: true).")
        }

        let primaryFile = litertlmFiles.first
        let resolvedSize = primaryFile?.resolvedSize
        let commitHash = primaryFile?.lfs?.oid ?? metadata.sha

        let isCompatible = hasLitertlm && supportsAudio

        if isCompatible {
            reasons.append("Model verified for on-device audio dictation pipeline (.litertlm + audio support).")
        }

        return ModelCompatibilityReport(
            modelId: metadata.id,
            isCompatible: isCompatible,
            hasLitertlmFormat: hasLitertlm,
            supportsAudio: supportsAudio,
            modelFilename: primaryFile?.rfilename,
            fileSizeBytes: resolvedSize,
            commitHash: commitHash,
            diagnosticReasons: reasons
        )
    }

    /// Fetches model metadata and verifies its audio compatibility in a single call.
    public func fetchAndVerifyModel(
        modelId: String,
        bearerToken: String? = nil
    ) async throws -> ModelCompatibilityReport {
        let metadata = try await fetchModelMetadata(modelId: modelId, bearerToken: bearerToken)
        return verifyCompatibility(metadata: metadata)
    }

    /// Filters a list of model IDs, returning compatibility reports for only audio-compatible models.
    public func filterCompatibleAudioModels(
        modelIds: [String],
        bearerToken: String? = nil
    ) async -> [ModelCompatibilityReport] {
        var compatibleReports: [ModelCompatibilityReport] = []

        for modelId in modelIds {
            if let report = try? await fetchAndVerifyModel(modelId: modelId, bearerToken: bearerToken),
               report.isCompatible {
                compatibleReports.append(report)
            }
        }

        return compatibleReports
    }
}
