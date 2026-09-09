#!/usr/bin/env python3
"""Static regression checks for the production microphone-to-LiteRT path."""

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent


class SpeechPipelineRegressionTests(unittest.TestCase):
    def test_microphone_starts_before_cold_model_load(self):
        source = (REPO_ROOT / "Sources/EdgeEloquent/App/DictationCoordinator.swift").read_text()
        start_method = source[source.index("public func startRecording()") : source.index("public func stopRecording()")]

        stream_index = start_method.index("let chunkStream = audioCapture.chunkStream")
        capture_index = start_method.index("try await audioCapture.startCapture()")
        model_index = start_method.index("let engine = try await self.resolveEngine()")

        self.assertLess(stream_index, capture_index, "Register the chunk consumer before AVAudioEngine starts.")
        self.assertLess(capture_index, model_index, "Do not lose speech while a cold model is loading.")

    def test_litert_audio_uses_file_and_non_streaming_native_path(self):
        source = (REPO_ROOT / "Sources/EdgeEloquent/Models/LiteRTGemmaEngine.swift").read_text()
        self.assertIn("useAudioFilePassing: Bool = true", source)
        self.assertIn("conversation.sendMessage(", source)
        self.assertNotIn("conversation.sendMessageStream(", source)
        self.assertIn("WAVEncoder.validateWAVHeader(wavData)", source)

    def test_downloadable_models_use_memory_safe_context(self):
        source = (REPO_ROOT / "Sources/EdgeEloquent/Models/SupportedAudioModel.swift").read_text()
        active_catalog = source[source.index("public static let gemma3n_E2B_it") : source.index("public static let allPredefined")]
        self.assertEqual(active_catalog.count("contextWindowTokens: 4_096"), 2)
        self.assertNotIn("contextWindowTokens: 16_384", active_catalog)

    def test_selected_litert_model_never_silently_falls_back_to_apple(self):
        source = (REPO_ROOT / "Sources/EdgeEloquent/App/DictationCoordinator.swift").read_text()
        resolver = source[source.index("private func resolveEngine()") : source.index("// MARK: - Dictation Actions")]

        self.assertNotIn("falling back to Apple Speech", resolver)
        self.assertIn('if selectedModelId == "apple-native-speech"', resolver)
        self.assertIn("catch let error as SpeechModelEngineError", resolver)

    def test_apple_on_device_capability_is_checked_before_recognition(self):
        source = (REPO_ROOT / "Sources/EdgeEloquent/Models/AppleOnDeviceSpeechEngine.swift").read_text()
        capability_index = source.index("if !recognizer.supportsOnDeviceRecognition")
        request_index = source.index("request.requiresOnDeviceRecognition = true")

        self.assertLess(capability_index, request_index)
        self.assertIn('nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1107', source)


if __name__ == "__main__":
    unittest.main()
