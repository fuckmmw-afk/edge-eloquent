//
//  CloudPostProcessor.swift
//  EdgeEloquent
//
//  Abstract Provider Protocol and Swappable Coordinator for Edge Eloquent Cloud Post-Processing.
//

import Foundation

/// Abstract protocol defining swappable cloud post-processing providers.
public protocol CloudPostProcessorProtocol: Sendable {
    /// Unique identifier for the provider (e.g., "cloudflare-workers-ai", "mock-offline").
    var providerId: String { get }
    
    /// Checks whether the provider is currently reachable and configured.
    var isAvailable: Bool { get async }
    
    /// Processes and enriches the raw transcript text.
    ///
    /// - Parameters:
    ///   - text: The raw or locally cleaned transcript string.
    ///   - language: Target language code (e.g., "en", "es").
    ///   - mode: Desired formatting and polish mode.
    ///   - enableWebSearch: Whether to perform grounded web search fact-checking.
    /// - Returns: The structured `CloudflareEnhanceResponse`.
    func enhance(
        text: String,
        language: String?,
        mode: EnhancementMode,
        enableWebSearch: Bool
    ) async throws -> CloudflareEnhanceResponse
}

/// Thread-safe coordinator managing the active cloud post-processing engine.
/// Allows dynamic hot-swapping between Cloudflare, local offline fallback, or mock providers.
public actor CloudPostProcessor {
    
    /// The currently active post-processing provider.
    private var activeProvider: CloudPostProcessorProtocol
    
    /// Secondary fallback provider if the primary provider fails (e.g. offline).
    private var fallbackProvider: CloudPostProcessorProtocol?
    
    /// Global toggle to enforce complete air-gapped local processing.
    public private(set) var isAirGappedMode: Bool = false
    
    public init(
        provider: CloudPostProcessorProtocol,
        fallbackProvider: CloudPostProcessorProtocol? = LocalOfflinePostProcessor()
    ) {
        self.activeProvider = provider
        self.fallbackProvider = fallbackProvider
    }
    
    /// Swap the active cloud provider at runtime (e.g., switching between development and production).
    public func setProvider(_ provider: CloudPostProcessorProtocol) {
        self.activeProvider = provider
    }
    
    /// Configure fallback provider.
    public func setFallbackProvider(_ fallback: CloudPostProcessorProtocol?) {
        self.fallbackProvider = fallback
    }
    
    /// Toggle air-gapped mode. When enabled, all network calls are completely bypassed.
    public func setAirGappedMode(_ enabled: Bool) {
        self.isAirGappedMode = enabled
    }
    
    /// Process text using the active provider with automatic fallback and strict text audit.
    public func process(
        text: String,
        language: String? = "en",
        mode: EnhancementMode = .standard,
        enableWebSearch: Bool = true
    ) async throws -> CloudflareEnhanceResponse {
        // STRICT PRIVACY GUARD: Text validation before anything else
        try StrictTextOnlyGuard.validateTextOnly(text)
        
        if isAirGappedMode {
            if let fallback = fallbackProvider {
                return try await fallback.enhance(
                    text: text,
                    language: language,
                    mode: mode,
                    enableWebSearch: false
                )
            } else {
                return CloudflareEnhanceResponse(
                    enhancedText: text,
                    confidence: 1.0,
                    correctionsCount: 0,
                    webInsights: [],
                    mode: mode.rawValue
                )
            }
        }
        
        do {
            return try await activeProvider.enhance(
                text: text,
                language: language,
                mode: mode,
                enableWebSearch: enableWebSearch
            )
        } catch {
            // Attempt graceful fallback if primary cloud provider encounters an error
            if let fallback = fallbackProvider {
                return try await fallback.enhance(
                    text: text,
                    language: language,
                    mode: mode,
                    enableWebSearch: false
                )
            }
            throw error
        }
    }
}

// MARK: - Local Offline Fallback Provider

/// Deterministic, purely on-device fallback post-processor used in air-gapped mode or offline states.
public struct LocalOfflinePostProcessor: CloudPostProcessorProtocol {
    public let providerId: String = "local-offline-fallback"
    
    public var isAvailable: Bool {
        get async { true }
    }
    
    public init() {}
    
    public func enhance(
        text: String,
        language: String?,
        mode: EnhancementMode,
        enableWebSearch: Bool
    ) async throws -> CloudflareEnhanceResponse {
        // Audit text
        try StrictTextOnlyGuard.validateTextOnly(text)
        
        var cleaned = text
        
        // Remove vocal filler words
        let fillerPatterns = ["\\b(um|uh|er|ah|like|you know|sort of|kind of|i mean)\\b",
                              "\\b(so\\s+basically|basically|actually)\\b"]
        for pattern in fillerPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    options: [],
                    range: NSRange(cleaned.startIndex..., in: cleaned),
                    withTemplate: ""
                )
            }
        }
        
        // Collapse immediate word repetitions: "the the" -> "the"
        if let repRegex = try? NSRegularExpression(pattern: "\\b([a-zA-Z]+)\\s+\\1\\b", options: .caseInsensitive) {
            cleaned = repRegex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: "$1"
            )
        }
        
        // Collapse whitespace
        cleaned = cleaned.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\s+([.,!?;:])", with: "$1", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Mode formatting
        switch mode {
        case .bulletPoints:
            let sentences = cleaned.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            cleaned = sentences.map { "\u{2022} \($0)." }.joined(separator: "\n")
        case .meetingNotes:
            cleaned = "### Meeting Notes\n- \(cleaned)"
        case .executiveSummary:
            cleaned = "**Executive Summary:** \(cleaned)"
        default:
            break
        }
        
        return CloudflareEnhanceResponse(
            enhancedText: cleaned,
            confidence: 0.95,
            correctionsCount: cleaned != text ? 1 : 0,
            webInsights: [],
            corrections: nil,
            mode: mode.rawValue,
            processingTimeMs: 1.0
        )
    }
}
