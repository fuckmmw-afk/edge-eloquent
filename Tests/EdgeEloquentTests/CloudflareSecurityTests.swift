//
//  CloudflareSecurityTests.swift
//  EdgeEloquentTests
//
//  CRITICAL SECURITY & REGRESSION TEST SUITE:
//  Verifies that raw audio, binary chunks, and unauthorized payloads are structurally
//  and deterministically blocked from exiting the device.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EdgeEloquent

final class CloudflareSecurityTests: XCTestCase {
    
    // MARK: - Test 1: Valid Text Payload Succeeds
    
    func testValidTextPayloadValidationSucceeds() throws {
        let sampleText = "The quarterly architecture review with the LiteRT team is scheduled for tomorrow at 2:00 PM."
        
        // 1. Text only validation
        XCTAssertNoThrow(try StrictTextOnlyGuard.validateTextOnly(sampleText))
        
        // 2. Outbound payload validation
        let requestPayload = CloudflareEnhanceRequest(
            text: sampleText,
            language: "en",
            mode: .professional,
            enableWebSearch: true
        )
        let encoder = JSONEncoder()
        let payloadData = try encoder.encode(requestPayload)
        let headers = ["Content-Type": "application/json; charset=utf-8"]
        
        XCTAssertNoThrow(try StrictTextOnlyGuard.validateOutboundPayload(payloadData, headers: headers))
        
        // 3. Outbound URLRequest validation
        var urlRequest = URLRequest(url: URL(string: "https://worker.example.com/api/enhance")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = payloadData
        for (k, v) in headers {
            urlRequest.setValue(v, forHTTPHeaderField: k)
        }
        
        XCTAssertNoThrow(try StrictTextOnlyGuard.validateOutboundRequest(urlRequest))
    }
    
    // MARK: - Test 2: Audio Leakage Regression - RIFF / WAV Audio Signature Rejected
    
    func testAudioLeakageRegressionRIFFWAVRejectedImmediately() throws {
        // Construct simulated 16kHz WAV header [0x52, 0x49, 0x46, 0x46] ("RIFF")
        var wavHeader = Data([0x52, 0x49, 0x46, 0x46])
        wavHeader.append(contentsOf: [0x24, 0x00, 0x00, 0x00]) // Size
        wavHeader.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        wavHeader.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        
        // Attempting to validate raw WAV data must throw audioMagicBytesDetected
        XCTAssertThrowsError(
            try StrictTextOnlyGuard.validateOutboundPayload(wavHeader, headers: ["Content-Type": "application/json"])
        ) { error in
            guard let violation = error as? StrictTextOnlyGuard.SecurityViolationError else {
                XCTFail("Expected SecurityViolationError, got \(error)")
                return
            }
            if case .audioMagicBytesDetected(let signature) = violation {
                XCTAssertEqual(signature, "RIFF/WAVE")
            } else {
                XCTFail("Expected audioMagicBytesDetected, got \(violation)")
            }
        }
    }
    
    // MARK: - Test 3: Audio Leakage Regression - OggS / Opus Rejected
    
    func testAudioLeakageRegressionOggOpusRejectedImmediately() throws {
        // "OggS" signature [0x4F, 0x67, 0x67, 0x53]
        let oggData = Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00])
        
        XCTAssertThrowsError(
            try StrictTextOnlyGuard.validateOutboundPayload(oggData, headers: ["Content-Type": "application/json"])
        ) { error in
            guard let violation = error as? StrictTextOnlyGuard.SecurityViolationError else {
                XCTFail("Expected SecurityViolationError, got \(error)")
                return
            }
            if case .audioMagicBytesDetected(let signature) = violation {
                XCTAssertTrue(signature.contains("OggS"))
            } else {
                XCTFail("Expected audioMagicBytesDetected, got \(violation)")
            }
        }
    }
    
    // MARK: - Test 4: Audio Leakage Regression - MP3 ID3 & Sync Frame Rejected
    
    func testAudioLeakageRegressionMP3SignaturesRejectedImmediately() throws {
        // 1. ID3 header
        let id3Data = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(
            try StrictTextOnlyGuard.validateOutboundPayload(id3Data, headers: ["Content-Type": "application/json"])
        ) { error in
            guard case .audioMagicBytesDetected(let sig) = error as? StrictTextOnlyGuard.SecurityViolationError else {
                XCTFail("Expected audioMagicBytesDetected, got \(error)")
                return
            }
            XCTAssertTrue(sig.contains("ID3"))
        }
        
        // 2. MP3 Frame Sync
        let syncData = Data([0xFF, 0xFB, 0x90, 0x64])
        XCTAssertThrowsError(
            try StrictTextOnlyGuard.validateOutboundPayload(syncData, headers: ["Content-Type": "application/json"])
        ) { error in
            guard case .audioMagicBytesDetected(let sig) = error as? StrictTextOnlyGuard.SecurityViolationError else {
                XCTFail("Expected audioMagicBytesDetected, got \(error)")
                return
            }
            XCTAssertTrue(sig.contains("Sync Frame"))
        }
    }
    
    // MARK: - Test 5: Audio Leakage Regression - FLAC Audio Signature Rejected
    
    func testAudioLeakageRegressionFLACRejectedImmediately() throws {
        // "fLaC" signature [0x66, 0x4C, 0x61, 0x43]
        let flacData = Data([0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22])
        XCTAssertThrowsError(
            try StrictTextOnlyGuard.validateOutboundPayload(flacData, headers: ["Content-Type": "application/json"])
        ) { error in
            guard case .audioMagicBytesDetected(let sig) = error as? StrictTextOnlyGuard.SecurityViolationError else {
                XCTFail("Expected audioMagicBytesDetected, got \(error)")
                return
            }
            XCTAssertTrue(sig.contains("FLAC"))
        }
    }
    
    // MARK: - Test 6: Audio Leakage Regression - M4A / ftyp Audio Signature Rejected
    
    func testAudioLeakageRegressionM4AFtypRejectedImmediately() throws {
        // "ftyp" signature [0x66, 0x74, 0x79, 0x70]
        let ftypData = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20])
        XCTAssertThrowsError(
            try StrictTextOnlyGuard.validateOutboundPayload(ftypData, headers: ["Content-Type": "application/json"])
        ) { error in
            guard case .audioMagicBytesDetected(let sig) = error as? StrictTextOnlyGuard.SecurityViolationError else {
                XCTFail("Expected audioMagicBytesDetected, got \(error)")
                return
            }
            XCTAssertTrue(sig.contains("ftyp"))
        }
    }
    
    // MARK: - Test 7: Audio Leakage Regression - Apple Core Audio (CAF) Rejected
    
    func testAudioLeakageRegressionAppleCAFRejectedImmediately() throws {
        // "caff" signature [0x63, 0x61, 0x66, 0x66]
        let cafData = Data([0x63, 0x61, 0x66, 0x66, 0x00, 0x01, 0x00, 0x00])
        XCTAssertThrowsError(
            try StrictTextOnlyGuard.validateOutboundPayload(cafData, headers: ["Content-Type": "application/json"])
        ) { error in
            guard case .audioMagicBytesDetected(let sig) = error as? StrictTextOnlyGuard.SecurityViolationError else {
                XCTFail("Expected audioMagicBytesDetected, got \(error)")
                return
            }
            XCTAssertTrue(sig.contains("Apple Core Audio"))
        }
    }
    
    // MARK: - Test 8: Base64 Disguised Audio Chunk Rejected
    
    func testDisguisedBase64AudioChunkRejected() throws {
        // Create a 300-byte pseudo audio chunk starting with RIFF WAV header
        var rawAudio = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])
        rawAudio.append(Data(repeating: 0x7F, count: 250))
        let base64Audio = rawAudio.base64EncodedString()
        
        let maliciousPayload = "{\"text\": \"Meeting notes: \(base64Audio)\"}"
        let maliciousData = maliciousPayload.data(using: .utf8)!
        
        XCTAssertThrowsError(
            try StrictTextOnlyGuard.validateOutboundPayload(maliciousData, headers: ["Content-Type": "application/json"])
        ) { error in
            guard let violation = error as? StrictTextOnlyGuard.SecurityViolationError else {
                XCTFail("Expected SecurityViolationError, got \(error)")
                return
            }
            switch violation {
            case .base64AudioPayloadDetected, .audioMagicBytesDetected:
                // Succeeded in detecting disguised audio
                break
            default:
                XCTFail("Expected base64 audio detection, got \(violation)")
            }
        }
    }
    
    // MARK: - Test 9: Binary Null Bytes in Outbound Data Rejected
    
    func testBinaryNullBytesRejected() throws {
        var rawData = "{\"text\": \"Hello world\"}".data(using: .utf8)!
        rawData.append(0x00) // Insert binary null
        
        XCTAssertThrowsError(
            try StrictTextOnlyGuard.validateOutboundPayload(rawData, headers: ["Content-Type": "application/json"])
        ) { error in
            XCTAssertEqual(error as? StrictTextOnlyGuard.SecurityViolationError, .binaryNullBytesDetected)
        }
    }
    
    // MARK: - Test 10: Non-JSON Content-Type Rejected
    
    func testInvalidContentTypeRejected() throws {
        let validData = "{\"text\": \"Hello world\"}".data(using: .utf8)!
        
        // 1. audio/wav
        XCTAssertThrowsError(
            try StrictTextOnlyGuard.validateOutboundRequest(
                createMockRequest(body: validData, contentType: "audio/wav")
            )
        ) { error in
            guard case .invalidContentType = error as? StrictTextOnlyGuard.SecurityViolationError else {
                XCTFail("Expected invalidContentType, got \(error)")
                return
            }
        }
        
        // 2. application/octet-stream
        XCTAssertThrowsError(
            try StrictTextOnlyGuard.validateOutboundRequest(
                createMockRequest(body: validData, contentType: "application/octet-stream")
            )
        )
        
        // 3. multipart/form-data
        XCTAssertThrowsError(
            try StrictTextOnlyGuard.validateOutboundRequest(
                createMockRequest(body: validData, contentType: "multipart/form-data; boundary=xyz")
            )
        )
    }
    
    // MARK: - Test 11: Excessive Payload Size Rejected
    
    func testExcessivePayloadSizeRejected() throws {
        // Create 600 KB payload exceeding 512 KB limit
        let hugeString = String(repeating: "A", count: 600 * 1024)
        let hugeData = try JSONEncoder().encode(["text": hugeString])
        
        XCTAssertThrowsError(
            try StrictTextOnlyGuard.validateOutboundPayload(hugeData, headers: ["Content-Type": "application/json"])
        ) { error in
            guard case .excessivePayloadSize = error as? StrictTextOnlyGuard.SecurityViolationError else {
                XCTFail("Expected excessivePayloadSize, got \(error)")
                return
            }
        }
    }
    
    // MARK: - Test 12: CRITICAL REGRESSION - CloudflareBrainService Rejects Audio BEFORE Network Call
    
    func testCloudflareBrainServiceBlocksAudioBeforeAnyNetworkCall() async throws {
        // Setup a mock URLSession that will assert if data(for:) is EVER invoked
        MockURLProtocol.reset()
        let session = makeMockSession()
        
        let config = CloudflareConfiguration(
            endpointURL: URL(string: "https://worker.example.com/api/enhance")!,
            apiToken: "test-token"
        )
        let service = CloudflareBrainService(configuration: config, session: session)
        
        // Audio signature inside text string: "RIFF" bytes
        let maliciousText = "Audio header: RIFF\u{00}\u{01}\u{02}\u{03}WAVEfmt"
        
        do {
            _ = try await service.enhance(text: maliciousText)
            XCTFail("Expected CloudflareBrainService to throw securityViolation, but it succeeded!")
        } catch let error as CloudflareBrainError {
            switch error {
            case .securityViolation:
                // PASS: Security violation caught
                break
            default:
                XCTFail("Expected securityViolation error, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        
        // CRITICAL INVARIANT: Verify ZERO network requests were dispatched!
        XCTAssertEqual(
            MockURLProtocol.requestCount,
            0,
            "CRITICAL SECURITY FAILURE: Network request was dispatched despite binary/audio payload!"
        )
    }
    
    // MARK: - Test 13: CloudflareBrainService Success Flow
    
    func testCloudflareBrainServiceSuccessFlow() async throws {
        MockURLProtocol.reset()
        let expectedResponse = """
        {
            "enhancedText": "We should finalize the migration tomorrow at 2:00 PM.",
            "confidence": 0.98,
            "correctionsCount": 2,
            "webInsights": [
                {
                    "title": "LiteRT Docs",
                    "url": "https://ai.google.dev/edge/litert",
                    "snippet": "LiteRT is Google's runtime for on-device AI",
                    "query": "LiteRT"
                }
            ],
            "mode": "professional",
            "processingTimeMs": 125.0
        }
        """
        MockURLProtocol.stubResponse(
            statusCode: 200,
            data: expectedResponse.data(using: .utf8)!
        )
        
        let session = makeMockSession()
        let config = CloudflareConfiguration(
            endpointURL: URL(string: "https://worker.example.com/api/enhance")!,
            apiToken: "test-token"
        )
        let service = CloudflareBrainService(configuration: config, session: session)
        
        let result = try await service.enhance(
            text: "Um we should finalize the migration tomorrow at 2pm.",
            mode: .professional,
            enableWebSearch: true
        )
        
        XCTAssertEqual(result.enhancedText, "We should finalize the migration tomorrow at 2:00 PM.")
        XCTAssertEqual(result.confidence, 0.98)
        XCTAssertEqual(result.correctionsCount, 2)
        XCTAssertEqual(result.webInsights.count, 1)
        XCTAssertEqual(result.webInsights[0].title, "LiteRT Docs")
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }
    
    // MARK: - Test 14: Swappable Provider & Air-Gapped Coordinator Mode
    
    func testSwappableCloudPostProcessor() async throws {
        let offlineProvider = LocalOfflinePostProcessor()
        let coordinator = CloudPostProcessor(provider: offlineProvider)
        
        // Enable air-gapped mode
        await coordinator.setAirGappedMode(true)
        let isAirGapped = await coordinator.isAirGappedMode
        XCTAssertTrue(isAirGapped)
        
        let rawSpokenText = "Um, so basically we the the team decided to proceed."
        let result = try await coordinator.process(text: rawSpokenText, mode: .standard)
        
        // Air-gapped fallback should remove vocal fillers and collapsed repetitions
        XCTAssertFalse(result.enhancedText.contains("um,"))
        XCTAssertFalse(result.enhancedText.contains("so basically"))
        XCTAssertFalse(result.enhancedText.contains("the the"))
        XCTAssertTrue(result.enhancedText.contains("the team decided to proceed"))
    }
    
    // MARK: - Helpers
    
    private func createMockRequest(body: Data, contentType: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://worker.example.com/api/enhance")!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return req
    }
    
    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - MockURLProtocol for Unit Testing

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var _requestCount: Int = 0
    private static var _stubData: Data?
    private static var _stubStatusCode: Int = 200
    
    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestCount
    }
    
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        _requestCount = 0
        _stubData = nil
        _stubStatusCode = 200
    }
    
    static func stubResponse(statusCode: Int, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        _stubStatusCode = statusCode
        _stubData = data
    }
    
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        MockURLProtocol.lock.lock()
        MockURLProtocol._requestCount += 1
        let statusCode = MockURLProtocol._stubStatusCode
        let data = MockURLProtocol._stubData ?? Data()
        MockURLProtocol.lock.unlock()
        
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json; charset=utf-8"
            ]
        )!
        
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    
    override func stopLoading() {}
}
