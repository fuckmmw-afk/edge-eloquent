//
//  CloudflareBrainService.swift
//  EdgeEloquent
//
//  HTTPS Client implementation for Cloudflare Workers AI post-processing.
//  Enforces the Audio Air-Gap Invariant with runtime assertions before any network transmission.
//

import Foundation

/// Configuration container for Cloudflare Brain Service.
/// SECURE CONFIGURATION: Secrets (e.g. apiToken) are provided via dependency injection or
/// secure environment variables / Keychain. Never hardcoded into the IPA or repository.
public struct CloudflareConfiguration: Sendable {
    public let endpointURL: URL
    public let apiToken: String?
    public let timeoutInterval: TimeInterval
    public let maxRetries: Int
    public let retryDelay: TimeInterval
    
    public init(
        endpointURL: URL,
        apiToken: String? = nil,
        timeoutInterval: TimeInterval = 15.0,
        maxRetries: Int = 3,
        retryDelay: TimeInterval = 0.5
    ) {
        self.endpointURL = endpointURL
        self.apiToken = apiToken
        self.timeoutInterval = timeoutInterval
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
    }
    
    /// Constructs configuration securely from environment variables if present, with safe fallback.
    public static func fromEnvironment(
        defaultURL: URL = URL(string: "https://invalid.invalid/api/enhance")!
    ) -> CloudflareConfiguration {
        let envURLString = ProcessInfo.processInfo.environment["EDGE_ELOQUENT_CF_URL"]
        let url = envURLString.flatMap(URL.init(string:)) ?? defaultURL
        let token = ProcessInfo.processInfo.environment["EDGE_ELOQUENT_CF_TOKEN"]
        
        return CloudflareConfiguration(
            endpointURL: url,
            apiToken: token,
            timeoutInterval: 15.0,
            maxRetries: 3,
            retryDelay: 0.5
        )
    }
}

/// Errors emitted by the CloudflareBrainService.
public enum CloudflareBrainError: Error, LocalizedError, Equatable {
    public static func == (lhs: CloudflareBrainError, rhs: CloudflareBrainError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidEndpoint, .invalidEndpoint):
            return true
        case (.securityViolation(let s1), .securityViolation(let s2)):
            return s1 == s2
        case (.httpError(let c1, let m1), .httpError(let c2, let m2)):
            return c1 == c2 && m1 == m2
        case (.decodingError(let m1), .decodingError(let m2)):
            return m1 == m2
        case (.networkError(let m1), .networkError(let m2)):
            return m1 == m2
        case (.emptyResponse, .emptyResponse):
            return true
        default:
            return false
        }
    }
    
    case invalidEndpoint
    case securityViolation(StrictTextOnlyGuard.SecurityViolationError)
    case httpError(statusCode: Int, message: String)
    case decodingError(message: String)
    case networkError(message: String)
    case emptyResponse
    
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The configured Cloudflare Worker endpoint URL is invalid."
        case .securityViolation(let error):
            return "Security violation: \(error.localizedDescription)"
        case .httpError(let code, let msg):
            return "Cloudflare Worker returned HTTP \(code): \(msg)"
        case .decodingError(let msg):
            return "Failed to decode Cloudflare response: \(msg)"
        case .networkError(let msg):
            return "Network communication error: \(msg)"
        case .emptyResponse:
            return "Received empty response body from Cloudflare Worker."
        }
    }
}

/// Cloudflare Brain Service implementing text enhancement and web search augmentation over HTTPS.
/// Implements `CloudPostProcessorProtocol` to support swappable provider architectures.
public final class CloudflareBrainService: CloudPostProcessorProtocol, @unchecked Sendable {
    
    public let providerId: String = "cloudflare-workers-ai"
    
    private let configuration: CloudflareConfiguration
    private let session: URLSession
    
    public init(
        configuration: CloudflareConfiguration,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        
        if let session = session {
            self.session = session
        } else {
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.timeoutIntervalForRequest = configuration.timeoutInterval
            sessionConfig.timeoutIntervalForResource = configuration.timeoutInterval * 2
            sessionConfig.tlsMinimumSupportedProtocolVersion = .TLSv13
            sessionConfig.httpAdditionalHeaders = [
                "User-Agent": "EdgeEloquent/1.0 (iOS; Apple Silicon)"
            ]
            self.session = URLSession(configuration: sessionConfig)
        }
    }
    
    public var isAvailable: Bool {
        get async {
            // Check health endpoint
            guard var components = URLComponents(url: configuration.endpointURL, resolvingAgainstBaseURL: false) else {
                return false
            }
            components.path = "/health"
            guard let healthURL = components.url else { return false }
            
            var request = URLRequest(url: healthURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 3.0
            
            do {
                let (_, response) = try await session.data(for: request)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    return true
                }
                return false
            } catch {
                return false
            }
        }
    }
    
    /// Enhances transcript text with strict runtime payload assertions and retry capability.
    public func enhance(
        text: String,
        language: String? = "en",
        mode: EnhancementMode = .standard,
        enableWebSearch: Bool = true
    ) async throws -> CloudflareEnhanceResponse {
        
        // -------------------------------------------------------------
        // RUNTIME ASSERTION 1: Verify Input Text
        // -------------------------------------------------------------
        do {
            try StrictTextOnlyGuard.validateTextOnly(text)
        } catch let violation as StrictTextOnlyGuard.SecurityViolationError {
            throw CloudflareBrainError.securityViolation(violation)
        }
        
        // -------------------------------------------------------------
        // RUNTIME ASSERTION 2: Serialize & Audit Outbound JSON Payload
        // -------------------------------------------------------------
        let requestPayload = CloudflareEnhanceRequest(
            text: text,
            language: language,
            mode: mode,
            enableWebSearch: enableWebSearch
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        let requestData: Data
        do {
            requestData = try encoder.encode(requestPayload)
        } catch {
            throw CloudflareBrainError.decodingError(message: "Failed to encode request: \(error.localizedDescription)")
        }
        
        var headers: [String: String] = [
            "Content-Type": "application/json; charset=utf-8",
            "Accept": "application/json"
        ]
        
        if let token = configuration.apiToken, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        
        // Audit payload before constructing request
        do {
            try StrictTextOnlyGuard.validateOutboundPayload(requestData, headers: headers)
        } catch let violation as StrictTextOnlyGuard.SecurityViolationError {
            throw CloudflareBrainError.securityViolation(violation)
        }
        
        // -------------------------------------------------------------
        // RUNTIME ASSERTION 3: Audit Outbound URLRequest Object
        // -------------------------------------------------------------
        var urlRequest = URLRequest(url: configuration.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeoutInterval
        urlRequest.httpBody = requestData
        for (k, v) in headers {
            urlRequest.setValue(v, forHTTPHeaderField: k)
        }
        
        do {
            try StrictTextOnlyGuard.validateOutboundRequest(urlRequest)
        } catch let violation as StrictTextOnlyGuard.SecurityViolationError {
            throw CloudflareBrainError.securityViolation(violation)
        }
        
        // -------------------------------------------------------------
        // DISPATCH WITH EXPONENTIAL BACKOFF RETRY
        // -------------------------------------------------------------
        return try await executeWithRetry(request: urlRequest)
    }
    
    // MARK: - Retry Loop
    
    private func executeWithRetry(request: URLRequest) async throws -> CloudflareEnhanceResponse {
        var lastError: Error?
        let maxRetries = configuration.maxRetries
        var currentDelay = configuration.retryDelay
        
        for attempt in 0...maxRetries {
            do {
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CloudflareBrainError.networkError(message: "Non-HTTP response received.")
                }
                
                // Inspect status code
                switch httpResponse.statusCode {
                case 200...299:
                    guard !data.isEmpty else {
                        throw CloudflareBrainError.emptyResponse
                    }
                    
                    let decoder = JSONDecoder()
                    do {
                        return try decoder.decode(CloudflareEnhanceResponse.self, from: data)
                    } catch {
                        throw CloudflareBrainError.decodingError(message: error.localizedDescription)
                    }
                    
                case 429, 502, 503, 504:
                    // Transient errors eligible for retry
                    let serverMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                    lastError = CloudflareBrainError.httpError(statusCode: httpResponse.statusCode, message: serverMessage)
                    
                    if attempt < maxRetries {
                        // Apply jitter to backoff delay
                        let jitter = Double.random(in: 0.1...0.3)
                        try await Task.sleep(nanoseconds: UInt64((currentDelay + jitter) * 1_000_000_000))
                        currentDelay *= 2.0
                        continue
                    }
                    
                default:
                    // Non-transient errors (e.g. 400, 401, 415, 422) fail immediately
                    let serverMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                    throw CloudflareBrainError.httpError(statusCode: httpResponse.statusCode, message: serverMessage)
                }
                
            } catch let error as CloudflareBrainError {
                throw error
            } catch {
                lastError = error
                if attempt < maxRetries {
                    let jitter = Double.random(in: 0.1...0.3)
                    try await Task.sleep(nanoseconds: UInt64((currentDelay + jitter) * 1_000_000_000))
                    currentDelay *= 2.0
                    continue
                }
            }
        }
        
        if let err = lastError as? CloudflareBrainError {
            throw err
        } else if let err = lastError {
            throw CloudflareBrainError.networkError(message: err.localizedDescription)
        } else {
            throw CloudflareBrainError.networkError(message: "Max retries exceeded without response.")
        }
    }
}
