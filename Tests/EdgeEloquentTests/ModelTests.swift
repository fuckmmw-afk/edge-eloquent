//
//  ModelTests.swift
//  EdgeEloquentTests
//
//  Created by ModelAgent on 2026-09-08.
//

import XCTest
@testable import EdgeEloquent

final class ModelTests: XCTestCase {
    
    func testOfficialAudioModelsPresence() {
        let models = ModelInfo.allLiteRTAudioModels
        let ids = Set(models.map { $0.id })
        
        XCTAssertTrue(ids.contains("gemma-3n-e2b-it"), "Gemma-3n-E2B-it must be supported.")
        XCTAssertTrue(ids.contains("gemma-3n-e4b-it"), "Gemma-3n-E4B-it must be supported.")
        XCTAssertFalse(ids.contains("qwen3-asr-0.6b"), "Qwen3-ASR must not be offered through the LiteRT-LM Conversation runtime.")
        XCTAssertTrue(ids.contains("vibevoice-asr-bitnet"), "VibeVoice-ASR-BitNet must be supported.")
        
        for model in models {
            XCTAssertTrue(model.supportsAudio, "Official models must declare audio capability.")
            XCTAssertTrue(model.modelFile.hasSuffix(".litertlm"), "Official models must be in .litertlm format.")
            XCTAssertGreaterThan(model.sizeInBytes, 100_000_000, "Production audio models must contain real weights.")
            XCTAssertFalse(model.commitHash.isEmpty, "Pinned commit hash must be defined.")
            XCTAssertEqual(model.accelerators.llm, .gpu, "LLM must be accelerated on GPU.")
            XCTAssertEqual(model.accelerators.audio, .cpu, "Audio Conformer must run on CPU.")
            XCTAssertNotNil(model.downloadURL, "Download URL must be generatable.")
            XCTAssertTrue(model.downloadURL?.absoluteString.contains("huggingface.co") == true)
        }
    }
    
    func testGemma4Features() {
        let gemma4 = ModelInfo.gemma4_E2B
        XCTAssertEqual(gemma4.maxContextTokens, 32_000)
        XCTAssertTrue(gemma4.supportsSpeculativeDecoding)
        XCTAssertTrue(gemma4.supportsThinking)
        XCTAssertTrue(gemma4.taskTypes.contains(.thinking))
    }
    
    func testGemma3nFeatures() {
        let gemma3n = ModelInfo.gemma3n_E2B
        XCTAssertEqual(gemma3n.maxContextTokens, 4_096)
        XCTAssertFalse(gemma3n.supportsSpeculativeDecoding)
        XCTAssertFalse(gemma3n.supportsThinking)
    }

    func testDownloadableGemmaModelsUseIOSMemorySafeContext() {
        for model in [SupportedAudioModel.gemma3n_E2B_it, SupportedAudioModel.gemma3n_E4B_it] {
            XCTAssertEqual(
                model.contextWindowTokens,
                4_096,
                "Audio transcription must not reserve an oversized KV cache on iOS."
            )
        }
        XCTAssertEqual(SupportedAudioModel.gemma3n_E2B_it.minRAMDescription, "6 GB")
        XCTAssertEqual(SupportedAudioModel.gemma3n_E4B_it.minRAMDescription, "8 GB")
    }

    func testQwenLegacyEntryIsExplicitlyRejectedByConversationRuntime() {
        let model = SupportedAudioModel.qwen3ASR_06B
        XCTAssertEqual(model.expectedBytes, 959_627_232)
        XCTAssertEqual(model.minRAMDescription, "4 GB")
        XCTAssertTrue(model.llmSupportAudio)
        XCTAssertFalse(model.llmSupportImage)
        XCTAssertEqual(model.contextWindowTokens, 1_024)
        XCTAssertEqual(model.recommendedAudioWindowSeconds, 5.0)
        XCTAssertFalse(model.supportsLiteRTLMConversation)
        XCTAssertTrue(model.runtimeCompatibilityMessage.contains("CompiledModel"))
    }

    func testApproximate187GiBModelIdentity() {
        let model = SupportedAudioModel.vibeVoiceASRBitNet
        XCTAssertEqual(model.expectedBytes, 1_983_019_248)
        XCTAssertEqual(model.minRAMDescription, "4 GB")
        XCTAssertEqual(model.expectedSHA256, "5ca907b0343d3e6bd9ec3dbf8aecbcc99b733633ef007a78a7e0f3502010af1b")
        XCTAssertEqual(model.recommendedAudioWindowSeconds, 15.0)
        XCTAssertTrue(model.supportsLiteRTLMConversation)
        XCTAssertEqual(SupportedAudioModel.defaultModel, model)
    }

    func testLiteRTAudioUsesNativeFilePathByDefault() {
        let engine = LiteRTGemmaEngine(modelInfo: .gemma3n_E2B)
        XCTAssertTrue(engine.useAudioFilePassing)
    }

    func testDefaultTranscriptionPromptPreservesSpokenLanguage() {
        let prompt = LiteRTGemmaEngine.defaultTranscriptionPrompt
        XCTAssertTrue(prompt.contains("language being spoken"))
        XCTAssertTrue(prompt.contains("Do not describe or translate"))
    }
    
    func testAppleNativeFallbackModel() {
        let fallback = ModelInfo.appleNative
        XCTAssertTrue(fallback.isSystemProvided)
        XCTAssertEqual(fallback.sizeInBytes, 0)
        XCTAssertEqual(fallback.formattedSize, "0 MB (Built-in)")
        XCTAssertNil(fallback.downloadURL)
        XCTAssertEqual(fallback.accelerators.llm, .neuralEngine)
    }

    func testAppleAssistant1107HasActionableError() {
        let rawError = NSError(
            domain: "kAFAssistantErrorDomain",
            code: 1107,
            userInfo: [NSLocalizedDescriptionKey: "The operation couldn't be completed."]
        )
        let mapped = AppleOnDeviceSpeechEngine.mappedRecognitionError(
            rawError,
            localeIdentifier: "ru-RU"
        )

        XCTAssertEqual(mapped, .onDeviceSpeechRecognitionUnavailable(locale: "ru-RU"))
        XCTAssertTrue(mapped.localizedDescription.contains("Dictation language"))
        XCTAssertTrue(mapped.localizedDescription.contains("Gemma"))
    }
    
    func testDeviceRAMCompatibility() {
        let gemma4_2b = ModelInfo.gemma4_E2B // Requires 8 GB
        XCTAssertFalse(gemma4_2b.isDeviceCompatible(deviceMemoryInGb: 6))
        XCTAssertTrue(gemma4_2b.isDeviceCompatible(deviceMemoryInGb: 8))
        XCTAssertTrue(gemma4_2b.isDeviceCompatible(deviceMemoryInGb: 16))
        
        let gemma4_4b = ModelInfo.gemma4_E4B // Requires 12 GB
        XCTAssertFalse(gemma4_4b.isDeviceCompatible(deviceMemoryInGb: 8))
        XCTAssertTrue(gemma4_4b.isDeviceCompatible(deviceMemoryInGb: 12))
        XCTAssertTrue(gemma4_4b.isDeviceCompatible(deviceMemoryInGb: 16))
    }
    
    func testEngineLifecycleState() async throws {
        let engine = LiteRTGemmaEngine(modelInfo: .gemma3n_E2B)
        XCTAssertFalse(engine.isLoaded)
        
        // Calling transcribeAudio without loading should throw modelNotLoaded
        let dummyWAV = Data(repeating: 0, count: 100)
        do {
            _ = try await engine.transcribeAudio(wavData: dummyWAV, prompt: nil)
            XCTFail("Should throw modelNotLoaded")
        } catch let error as SpeechModelEngineError {
            XCTAssertEqual(error, .modelNotLoaded)
        }
        
        await engine.unload()
        XCTAssertFalse(engine.isLoaded)
    }
    
    func testAppleOnDeviceSpeechEngineLifecycle() async throws {
        let engine = AppleOnDeviceSpeechEngine()
        XCTAssertFalse(engine.isLoaded)
        
        do {
            try await engine.load()
            XCTAssertTrue(engine.isLoaded)
            await engine.unload()
            XCTAssertFalse(engine.isLoaded)
        } catch {
            // Permission or availability restrictions in headless CI environments
            XCTAssertFalse(engine.isLoaded)
        }
    }
}
