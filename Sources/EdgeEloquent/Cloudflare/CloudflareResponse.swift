//
//  CloudflareResponse.swift
//  EdgeEloquent
//
//  Codable response and request structures for Edge Eloquent Cloudflare integration.
//

import Foundation

/// Supported enhancement modes for the Cloudflare Worker post-processing engine.
public enum EnhancementMode: String, Codable, Sendable, CaseIterable {
    case standard = "standard"
    case professional = "professional"
    case bulletPoints = "bullet_points"
    case meetingNotes = "meeting_notes"
    case executiveSummary = "executive_summary"
    case academic = "academic"
    
    public var displayName: String {
        switch self {
        case .standard: return "Standard Polish"
        case .professional: return "Professional Prose"
        case .bulletPoints: return "Bullet Points"
        case .meetingNotes: return "Meeting Notes"
        case .executiveSummary: return "Executive Summary"
        case .academic: return "Academic Formality"
        }
    }
}

/// Request model dispatched to the Cloudflare Worker `/api/enhance` endpoint.
/// Note: Contains ONLY strongly-typed text primitives. Non-text or binary data cannot be passed.
public struct CloudflareEnhanceRequest: Codable, Sendable, Equatable {
    public let text: String
    public let language: String?
    public let mode: EnhancementMode
    public let enableWebSearch: Bool
    public let clientRequestId: UUID?
    public let timestamp: Date?
    
    public init(
        text: String,
        language: String? = "en",
        mode: EnhancementMode = .standard,
        enableWebSearch: Bool = true,
        clientRequestId: UUID? = UUID(),
        timestamp: Date? = Date()
    ) {
        self.text = text
        self.language = language
        self.mode = mode
        self.enableWebSearch = enableWebSearch
        self.clientRequestId = clientRequestId
        self.timestamp = timestamp
    }
}

/// Individual web search citation and insight returned from Cloudflare edge worker.
public struct WebInsight: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let url: String
    public let snippet: String
    public let query: String
    
    public init(
        id: UUID = UUID(),
        title: String,
        url: String,
        snippet: String,
        query: String
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
        self.query = query
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case url
        case snippet
        case query
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decode(String.self, forKey: .title)
        self.url = try container.decode(String.self, forKey: .url)
        self.snippet = try container.decode(String.self, forKey: .snippet)
        self.query = try container.decode(String.self, forKey: .query)
    }
}

/// Granular text correction detail tracking modifications.
public struct TextCorrection: Codable, Sendable, Equatable {
    public let original: String
    public let replacement: String
    public let reason: String?
    
    public init(original: String, replacement: String, reason: String? = nil) {
        self.original = original
        self.replacement = replacement
        self.reason = reason
    }
}

/// The atomic response payload returned by the Cloudflare Worker `/api/enhance` endpoint.
public struct CloudflareEnhanceResponse: Codable, Sendable, Equatable {
    /// Polished, formatted transcript prose.
    public let enhancedText: String
    
    /// Estimated confidence score (0.0 to 1.0).
    public let confidence: Double
    
    /// Total number of grammar, punctuation, and disfluency corrections made.
    public let correctionsCount: Int
    
    /// Fact-checking citations and synthesized web search insights.
    public let webInsights: [WebInsight]
    
    /// Optional granular corrections diff.
    public let corrections: [TextCorrection]?
    
    /// The enhancement mode applied.
    public let mode: String?
    
    /// Server processing latency in milliseconds.
    public let processingTimeMs: Double?
    
    public init(
        enhancedText: String,
        confidence: Double = 0.98,
        correctionsCount: Int = 0,
        webInsights: [WebInsight] = [],
        corrections: [TextCorrection]? = nil,
        mode: String? = nil,
        processingTimeMs: Double? = nil
    ) {
        self.enhancedText = enhancedText
        self.confidence = confidence
        self.correctionsCount = correctionsCount
        self.webInsights = webInsights
        self.corrections = corrections
        self.mode = mode
        self.processingTimeMs = processingTimeMs
    }
    
    enum CodingKeys: String, CodingKey {
        case enhancedText
        case confidence
        case correctionsCount
        case webInsights
        case corrections
        case mode
        case processingTimeMs
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enhancedText = try container.decode(String.self, forKey: .enhancedText)
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.98
        self.correctionsCount = try container.decodeIfPresent(Int.self, forKey: .correctionsCount) ?? 0
        self.webInsights = try container.decodeIfPresent([WebInsight].self, forKey: .webInsights) ?? []
        self.corrections = try container.decodeIfPresent([TextCorrection].self, forKey: .corrections)
        self.mode = try container.decodeIfPresent(String.self, forKey: .mode)
        self.processingTimeMs = try container.decodeIfPresent(Double.self, forKey: .processingTimeMs)
    }
}
