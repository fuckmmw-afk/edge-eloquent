//
//  SecurityAssertionTests.swift
//  EdgeEloquentTests
//
//  Security and Privacy Verification Suite:
//  Verifies that the Audio Air-Gap Invariant and StrictTextOnlyGuard
//  prevent any audio frames, non-text binaries, or model weights from leaking.
//

import XCTest
@testable import EdgeEloquent

final class SecurityAssertionTests: XCTestCase {

    // MARK: - Valid Text Payload Tests

    func testValidJsonPayloadPasses() throws {
        let validPayload = """
        {
            "text": "Hello world, this is a clean transcript.",
            "mode": "standard",
            "enableWebSearch": true
        }
        """.data(using: .utf8)!

        let headers = ["Content-Type": "application/json; charset=utf-8"]
        XCTAssertNoThrow(try StrictTextOnlyGuard.validateOutboundPayload(validPayload, headers: headers))
    }

    func testOrdinaryMagicWordsRemainValidText() throws {
        XCTAssertNoThrow(try StrictTextOnlyGuard.validateTextOnly("FORM a RIFF with the ID3 team."))
    }

    func testValidOutboundURLRequestPasses() throws {
        var request = URLRequest(url: URL(string: "https://worker.edge-eloquent.workers.dev/api/enhance")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = """
        {
            "text": "Meeting scheduled for tomorrow at 10 AM.",
            "language": "en",
            "mode": "professional"
        }
        """.data(using: .utf8)

        XCTAssertNoThrow(try StrictTextOnlyGuard.validateOutboundRequest(request))
    }

    // MARK: - Method and Header Violations

    func testNonPostMethodRejected() {
        var request = URLRequest(url: URL(string: "https://worker.edge-eloquent.workers.dev/api/enhance")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{\"text\": \"test\"}".data(using: .utf8)

        XCTAssertThrowsError(try StrictTextOnlyGuard.validateOutboundRequest(request)) { error in
            guard case StrictTextOnlyGuard.SecurityViolationError.invalidContentType = error else {
                XCTFail("Expected invalidContentType error, got \(error)")
                return
            }
        }
    }

    func testAudioContentTypeRejected() {
        var request = URLRequest(url: URL(string: "https://worker.edge-eloquent.workers.dev/api/enhance")!)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data([0x52, 0x49, 0x46, 0x46])

        XCTAssertThrowsError(try StrictTextOnlyGuard.validateOutboundRequest(request)) { error in
            guard case StrictTextOnlyGuard.SecurityViolationError.invalidContentType = error else {
                XCTFail("Expected invalidContentType error, got \(error)")
                return
            }
        }
    }

    func testOctetStreamContentTypeRejected() {
        var request = URLRequest(url: URL(string: "https://worker.edge-eloquent.workers.dev/api/enhance")!)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{\"text\":\"hello\"}".data(using: .utf8)

        XCTAssertThrowsError(try StrictTextOnlyGuard.validateOutboundRequest(request)) { error in
            guard case StrictTextOnlyGuard.SecurityViolationError.invalidContentType = error else {
                XCTFail("Expected invalidContentType error, got \(error)")
                return
            }
        }
    }

    // MARK: - Audio Magic Bytes Injection Tests

    func testRiffWaveAudioMagicBytesRejected() {
        var payloadData = "{\"text\": \"transcript\", \"dummy\": \"".data(using: .utf8)!
        payloadData.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        payloadData.append("\"}".data(using: .utf8)!)

        let headers = ["Content-Type": "application/json"]
        XCTAssertThrowsError(try StrictTextOnlyGuard.validateOutboundPayload(payloadData, headers: headers)) { error in
            guard case StrictTextOnlyGuard.SecurityViolationError.audioMagicBytesDetected(let sig) = error else {
                XCTFail("Expected audioMagicBytesDetected, got \(error)")
                return
            }
            XCTAssertTrue(sig.contains("RIFF"))
        }
    }

    func testOggAudioMagicBytesRejected() {
        var payloadData = "{\"text\": \"transcript\", \"dummy\": \"".data(using: .utf8)!
        payloadData.append(contentsOf: [0x4F, 0x67, 0x67, 0x53]) // "OggS"
        payloadData.append("\"}".data(using: .utf8)!)

        let headers = ["Content-Type": "application/json"]
        XCTAssertThrowsError(try StrictTextOnlyGuard.validateOutboundPayload(payloadData, headers: headers)) { error in
            guard case StrictTextOnlyGuard.SecurityViolationError.audioMagicBytesDetected(let sig) = error else {
                XCTFail("Expected audioMagicBytesDetected, got \(error)")
                return
            }
            XCTAssertTrue(sig.contains("OggS"))
        }
    }

    func testFlacAudioMagicBytesRejected() {
        var payloadData = "{\"text\": \"transcript\", \"dummy\": \"".data(using: .utf8)!
        payloadData.append(contentsOf: [0x66, 0x4C, 0x61, 0x43]) // "fLaC"
        payloadData.append("\"}".data(using: .utf8)!)

        let headers = ["Content-Type": "application/json"]
        XCTAssertThrowsError(try StrictTextOnlyGuard.validateOutboundPayload(payloadData, headers: headers)) { error in
            guard case StrictTextOnlyGuard.SecurityViolationError.audioMagicBytesDetected(let sig) = error else {
                XCTFail("Expected audioMagicBytesDetected, got \(error)")
                return
            }
            XCTAssertTrue(sig.contains("fLaC"))
        }
    }

    // MARK: - Binary Null Bytes & Non-UTF8 Tests

    func testBinaryNullBytesRejected() {
        var payloadData = "{\"text\": \"clean text".data(using: .utf8)!
        payloadData.append(0x00) // null byte
        payloadData.append("\"}".data(using: .utf8)!)

        let headers = ["Content-Type": "application/json"]
        XCTAssertThrowsError(try StrictTextOnlyGuard.validateOutboundPayload(payloadData, headers: headers)) { error in
            guard case StrictTextOnlyGuard.SecurityViolationError.binaryNullBytesDetected = error else {
                XCTFail("Expected binaryNullBytesDetected, got \(error)")
                return
            }
        }
    }

    // MARK: - Excessive Payload Size Guard

    func testExcessivePayloadRejected() {
        // Exceeds maxTextPayloadBytes (512 KB)
        let oversizedString = String(repeating: "a", count: 520 * 1024)
        let payloadData = "{\"text\": \"\(oversizedString)\"}".data(using: .utf8)!

        let headers = ["Content-Type": "application/json"]
        XCTAssertThrowsError(try StrictTextOnlyGuard.validateOutboundPayload(payloadData, headers: headers)) { error in
            guard case StrictTextOnlyGuard.SecurityViolationError.excessivePayloadSize = error else {
                XCTFail("Expected excessivePayloadSize, got \(error)")
                return
            }
        }
    }

    // MARK: - Zero Model Weights Invariant Assertion

    func testZeroModelWeightsBundledInvariant() {
        // Assert that all LiteRT-LM models declare remote download URLs and are NOT marked as system provided
        let models = ModelInfo.allLiteRTAudioModels
        XCTAssertFalse(models.isEmpty, "LiteRT audio models list should not be empty.")

        for model in models {
            XCTAssertFalse(model.isSystemProvided, "Model \(model.id) must NOT be marked as system provided / bundled.")
            XCTAssertNotNil(model.downloadURL, "Model \(model.id) must specify an external download URL.")
            XCTAssertGreaterThan(model.sizeInBytes, 500_000_000, "Model \(model.id) weights are massive (>500MB) and must not be bundled.")
            XCTAssertFalse(model.isLocallyCached, "Fresh installations must not have locally cached model weights.")
        }
    }
}
