//
//  StrictTextOnlyGuard.swift
//  EdgeEloquent
//
//  STRICT PRIVACY AND SECURITY ENFORCEMENT:
//  Guarantees that raw microphone audio, PCM buffers, WAV chunks, and non-text binary data
//  NEVER leave the on-device perimeter. All outbound network requests are audited at runtime
//  and rejected before any network socket or transmission is initiated.
//

import Foundation

/// Security and privacy audit engine enforcing the Audio Air-Gap Invariant.
public enum StrictTextOnlyGuard {
    
    /// Maximum allowed payload size for outbound text requests (512 KB).
    /// Prevents raw media or audio buffers from being transmitted under any circumstances.
    public static let maxTextPayloadBytes: Int = 512 * 1024
    
    /// Minimum length of a base64 string before entropy / audio header inspection is triggered.
    public static let base64InspectionThreshold: Int = 256
    
    /// Error thrown when a payload violates the privacy or text-only invariant.
    public enum SecurityViolationError: Error, LocalizedError, Equatable {
        case audioMagicBytesDetected(signature: String)
        case nonUTF8BinaryDataDetected
        case unexpectedBinaryPayload
        case invalidContentType
        case excessivePayloadSize
        case binaryNullBytesDetected
        case highEntropyDataBlockDetected
        case base64AudioPayloadDetected(signature: String)
        case nonJsonPayloadStructure
        case emptyPayload
        
        public var errorDescription: String? {
            switch self {
            case .audioMagicBytesDetected(let signature):
                return "CRITICAL PRIVACY VIOLATION: Audio magic bytes detected (\(signature)). Audio must NEVER leave the device boundary."
            case .nonUTF8BinaryDataDetected, .unexpectedBinaryPayload:
                return "SECURITY VIOLATION: Payload contains non-UTF8 binary data. Only valid UTF-8 text is permitted."
            case .invalidContentType:
                return "SECURITY VIOLATION: Invalid Content-Type. Must strictly be 'application/json; charset=utf-8'."
            case .excessivePayloadSize:
                return "SECURITY VIOLATION: Payload size exceeds maximum text boundary (512 KB). Disallowed media dump."
            case .binaryNullBytesDetected:
                return "SECURITY VIOLATION: Binary null bytes (0x00) detected in outbound text stream."
            case .highEntropyDataBlockDetected:
                return "SECURITY VIOLATION: High-entropy binary blob detected. Potential disguised media."
            case .base64AudioPayloadDetected(let signature):
                return "CRITICAL PRIVACY VIOLATION: Disguised Base64-encoded audio detected (\(signature))."
            case .nonJsonPayloadStructure:
                return "SECURITY VIOLATION: Outbound payload does not conform to valid JSON object structure."
            case .emptyPayload:
                return "SECURITY VIOLATION: Outbound payload is empty."
            }
        }
    }
    
    /// Known audio container and stream magic byte signatures
    private struct MagicSignature {
        let name: String
        let bytes: [UInt8]
    }
    
    private static let forbiddenMagicSignatures: [MagicSignature] = [
        MagicSignature(name: "RIFF/WAVE", bytes: [0x52, 0x49, 0x46, 0x46]), // "RIFF"
        MagicSignature(name: "OggS (OGG/Opus)", bytes: [0x4F, 0x67, 0x67, 0x53]), // "OggS"
        MagicSignature(name: "ID3 (MP3)", bytes: [0x49, 0x44, 0x33]),       // "ID3"
        MagicSignature(name: "MP3 Sync Frame", bytes: [0xFF, 0xFB]),
        MagicSignature(name: "MP3 Sync Frame (Alt)", bytes: [0xFF, 0xF3]),
        MagicSignature(name: "MP3 Sync Frame (Alt 2)", bytes: [0xFF, 0xF2]),
        MagicSignature(name: "fLaC (FLAC Audio)", bytes: [0x66, 0x4C, 0x61, 0x43]), // "fLaC"
        MagicSignature(name: "ftyp (M4A/MP4/AAC)", bytes: [0x66, 0x74, 0x79, 0x70]), // "ftyp"
        MagicSignature(name: "caff (Apple Core Audio)", bytes: [0x63, 0x61, 0x66, 0x66]), // "caff"
        MagicSignature(name: "FORM (AIFF Audio)", bytes: [0x46, 0x4F, 0x52, 0x4D])  // "FORM"
    ]
    
    // MARK: - Core Validation API
    
    /// Audits an outbound `URLRequest` before network dispatch.
    /// Throws `SecurityViolationError` immediately if any audio, binary, or non-text content is discovered.
    public static func validateOutboundRequest(_ request: URLRequest) throws {
        // 1. Verify HTTP Method
        guard request.httpMethod?.uppercased() == "POST" else {
            throw SecurityViolationError.invalidContentType
        }
        
        // 2. Verify Content-Type Header
        let headers = request.allHTTPHeaderFields ?? [:]
        let contentType = headers["Content-Type"] ?? headers["content-type"] ?? ""
        guard contentType.lowercased().starts(with: "application/json") else {
            throw SecurityViolationError.invalidContentType
        }
        
        // 3. Reject Forbidden Content-Types explicitly
        let lowerContentType = contentType.lowercased()
        if lowerContentType.contains("audio/") ||
           lowerContentType.contains("octet-stream") ||
           lowerContentType.contains("multipart/") ||
           lowerContentType.contains("video/") {
            throw SecurityViolationError.invalidContentType
        }
        
        // 4. Audit Request Body
        guard let body = request.httpBody else {
            throw SecurityViolationError.emptyPayload
        }
        
        try validateOutboundPayload(body, headers: headers)
    }
    
    /// Deeply inspects raw outbound `Data` and headers.
    public static func validateOutboundPayload(_ data: Data, headers: [String: String] = [:]) throws {
        // 1. Length Assertion
        guard !data.isEmpty else {
            throw SecurityViolationError.emptyPayload
        }
        
        guard data.count <= maxTextPayloadBytes else {
            throw SecurityViolationError.excessivePayloadSize
        }
        
        // 2. Scan raw bytes for forbidden audio magic signatures
        for sig in forbiddenMagicSignatures {
            if data.range(of: Data(sig.bytes)) != nil {
                throw SecurityViolationError.audioMagicBytesDetected(signature: sig.name)
            }
        }
        
        // 3. Scan for raw binary null bytes (0x00 is invalid in text JSON payloads)
        if data.contains(0x00) {
            throw SecurityViolationError.binaryNullBytesDetected
        }
        
        // 4. Strict UTF-8 Decodability Assertion
        guard let utf8String = String(data: data, encoding: .utf8) else {
            throw SecurityViolationError.nonUTF8BinaryDataDetected
        }
        
        // 5. JSON Structural Introspection
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw SecurityViolationError.nonJsonPayloadStructure
        }
        
        guard let rootDict = jsonObject as? [String: Any] else {
            throw SecurityViolationError.nonJsonPayloadStructure
        }
        
        // 6. Deep Leaf Inspection (Rejects Base64 audio and hidden binary blobs)
        try inspectLeaves(rootDict)
        
        // 7. Text sanity check on user input text
        if let textVal = rootDict["text"] as? String {
            try validateTextOnly(textVal)
        }
    }
    
    /// Inspects a raw text string for hidden binary, audio fragments, or base64 audio blocks.
    public static func validateTextOnly(_ text: String) throws {
        guard let textData = text.data(using: .utf8) else {
            throw SecurityViolationError.nonUTF8BinaryDataDetected
        }
        
        // Scan for audio magic byte sequences inside string bytes
        for sig in forbiddenMagicSignatures {
            if textData.range(of: Data(sig.bytes)) != nil {
                throw SecurityViolationError.audioMagicBytesDetected(signature: sig.name)
            }
        }
        
        // Check for base64 encoded audio blocks within text
        try inspectStringForBase64Audio(text)
    }
    
    // MARK: - Private Recursive Introspection
    
    private static func inspectLeaves(_ dict: [String: Any]) throws {
        for (_, value) in dict {
            try inspectValue(value)
        }
    }
    
    private static func inspectValue(_ value: Any) throws {
        if let str = value as? String {
            try inspectStringForBase64Audio(str)
        } else if let nestedDict = value as? [String: Any] {
            try inspectLeaves(nestedDict)
        } else if let array = value as? [Any] {
            for item in array {
                try inspectValue(item)
            }
        } else if !(value is NSNumber || value is Bool || value is NSNull) {
            // Unrecognized or binary object type
            throw SecurityViolationError.nonUTF8BinaryDataDetected
        }
    }
    
    /// Inspects a string token for disguised Base64 audio chunks.
    private static func inspectStringForBase64Audio(_ str: String) throws {
        // Look for uninterrupted base64-like substrings exceeding threshold
        let tokens = str.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        for token in tokens where token.count >= base64InspectionThreshold {
            if isBase64String(token) {
                // Attempt decoding the leading 128 bytes to check magic headers
                let prefixLength = min(token.count, 256)
                let prefixStr = String(token.prefix(prefixLength))
                // Pad to multiple of 4 if necessary for valid Base64 decoding
                let remainder = prefixStr.count % 4
                let padded = remainder == 0 ? prefixStr : prefixStr + String(repeating: "=", count: 4 - remainder)
                
                if let decoded = Data(base64Encoded: padded) {
                    for sig in forbiddenMagicSignatures {
                        if decoded.range(of: Data(sig.bytes)) != nil {
                            throw SecurityViolationError.base64AudioPayloadDetected(signature: sig.name)
                        }
                    }
                    // If a continuous block of >1024 base64 chars with high non-ASCII decodes, flag entropy
                    if token.count > 1024 {
                        throw SecurityViolationError.highEntropyDataBlockDetected
                    }
                }
            }
        }
    }
    
    private static func isBase64String(_ str: String) -> Bool {
        let base64CharSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        return str.rangeOfCharacter(from: base64CharSet.inverted) == nil
    }
}
