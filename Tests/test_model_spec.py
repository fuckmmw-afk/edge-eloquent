#!/usr/bin/env python3
"""
Model Specifications and Integrity Tests for Edge Eloquent.
Validates:
- Official Google AI Edge Gallery allowlist models
- Audio capability flags (llmSupportAudio: true)
- Target container format (.litertlm)
- Commit hash pinning and immutability
- Hardware accelerator mapping
- Memory constraints & device RAM compatibility checks
- Absence of model weights from git repository and packaging
"""

import unittest
import subprocess
import os
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


class ModelInfo:
    def __init__(
        self,
        id: str,
        name: str,
        model_id: str,
        model_file: str,
        size_in_bytes: int,
        min_device_memory_gb: int,
        commit_hash: str,
        llm_accel: str,
        audio_accel: str,
        supports_audio: bool = True,
        supports_vision: bool = True,
        supports_speculative: bool = False,
        supports_thinking: bool = False,
        is_system_provided: bool = False,
        max_context_tokens: int = 4096,
    ):
        self.id = id
        self.name = name
        self.model_id = model_id
        self.model_file = model_file
        self.size_in_bytes = size_in_bytes
        self.min_device_memory_gb = min_device_memory_gb
        self.commit_hash = commit_hash
        self.llm_accel = llm_accel
        self.audio_accel = audio_accel
        self.supports_audio = supports_audio
        self.supports_vision = supports_vision
        self.supports_speculative = supports_speculative
        self.supports_thinking = supports_thinking
        self.is_system_provided = is_system_provided
        self.max_context_tokens = max_context_tokens

    @property
    def download_url(self) -> str | None:
        if self.is_system_provided:
            return None
        return f"https://huggingface.co/{self.model_id}/resolve/{self.commit_hash}/{self.model_file}?download=true"

    def is_device_compatible(self, ram_gb: int) -> bool:
        return ram_gb >= self.min_device_memory_gb


OFFICIAL_LITERTLM_MODELS = [
    ModelInfo(
        id="gemma-4-e2b-it",
        name="Gemma-4-E2B-it",
        model_id="litert-community/gemma-4-E2B-it-litert-lm",
        model_file="gemma-4-E2B-it.litertlm",
        size_in_bytes=2_588_147_712,
        min_device_memory_gb=8,
        commit_hash="6e5c4f1e395deb959c494953478fa5cec4b8008f",
        llm_accel="gpu",
        audio_accel="cpu",
        supports_audio=True,
        supports_vision=True,
        supports_speculative=True,
        supports_thinking=True,
        is_system_provided=False,
        max_context_tokens=32_000,
    ),
    ModelInfo(
        id="gemma-4-e4b-it",
        name="Gemma-4-E4B-it",
        model_id="litert-community/gemma-4-E4B-it-litert-lm",
        model_file="gemma-4-E4B-it.litertlm",
        size_in_bytes=3_659_530_240,
        min_device_memory_gb=12,
        commit_hash="28299f30ee4d43294517a4ac93abd6163412f07f",
        llm_accel="gpu",
        audio_accel="cpu",
        supports_audio=True,
        supports_vision=True,
        supports_speculative=True,
        supports_thinking=True,
        is_system_provided=False,
        max_context_tokens=32_000,
    ),
    ModelInfo(
        id="gemma-3n-e2b-it",
        name="Gemma-3n-E2B-it",
        model_id="google/gemma-3n-E2B-it-litert-lm",
        model_file="gemma-3n-E2B-it-int4.litertlm",
        size_in_bytes=3_388_604_416,
        min_device_memory_gb=6,
        commit_hash="73b019b63436d346f68dd9c1dbfd117eb264d888",
        llm_accel="gpu",
        audio_accel="cpu",
        supports_audio=True,
        supports_vision=True,
        supports_speculative=False,
        supports_thinking=False,
        is_system_provided=False,
        max_context_tokens=4_096,
    ),
    ModelInfo(
        id="gemma-3n-e4b-it",
        name="Gemma-3n-E4B-it",
        model_id="google/gemma-3n-E4B-it-litert-lm",
        model_file="gemma-3n-E4B-it-int4.litertlm",
        size_in_bytes=4_652_318_720,
        min_device_memory_gb=8,
        commit_hash="3d0179a0648381585ab337e170b7517aae8e0ce4",
        llm_accel="gpu",
        audio_accel="cpu",
        supports_audio=True,
        supports_vision=True,
        supports_speculative=False,
        supports_thinking=False,
        is_system_provided=False,
        max_context_tokens=4_096,
    ),
]

APPLE_NATIVE_MODEL = ModelInfo(
    id="apple-native-speech",
    name="Apple Native Speech",
    model_id="apple/on-device-speech",
    model_file="system-embedded",
    size_in_bytes=0,
    min_device_memory_gb=4,
    commit_hash="system",
    llm_accel="neuralEngine",
    audio_accel="neuralEngine",
    supports_audio=True,
    supports_vision=False,
    supports_speculative=False,
    supports_thinking=False,
    is_system_provided=True,
    max_context_tokens=4_096,
)


class TestModelSpecifications(unittest.TestCase):

    def test_official_audio_models_presence(self):
        ids = {m.id for m in OFFICIAL_LITERTLM_MODELS}
        self.assertIn("gemma-4-e2b-it", ids)
        self.assertIn("gemma-4-e4b-it", ids)
        self.assertIn("gemma-3n-e2b-it", ids)
        self.assertIn("gemma-3n-e4b-it", ids)

    def test_official_models_metadata_integrity(self):
        for model in OFFICIAL_LITERTLM_MODELS:
            self.assertTrue(model.supports_audio, f"{model.id} must support audio.")
            self.assertTrue(
                model.model_file.endswith(".litertlm"),
                f"{model.id} modelFile must end with .litertlm",
            )
            self.assertGreater(
                model.size_in_bytes, 1_000_000_000, f"{model.id} size must exceed 1GB."
            )
            self.assertTrue(
                len(model.commit_hash) >= 40,
                f"{model.id} commit hash must be full 40-char SHA.",
            )
            self.assertEqual(model.llm_accel, "gpu", "LLM must be accelerated on GPU.")
            self.assertEqual(
                model.audio_accel, "cpu", "Audio conformer must run on CPU."
            )
            self.assertIsNotNone(model.download_url)
            self.assertIn("huggingface.co", model.download_url)
            self.assertFalse(model.is_system_provided)

    def test_gemma4_advanced_features(self):
        gemma4 = next(m for m in OFFICIAL_LITERTLM_MODELS if m.id == "gemma-4-e2b-it")
        self.assertEqual(gemma4.max_context_tokens, 32_000)
        self.assertTrue(gemma4.supports_speculative)
        self.assertTrue(gemma4.supports_thinking)

    def test_gemma3n_baseline_features(self):
        gemma3n = next(m for m in OFFICIAL_LITERTLM_MODELS if m.id == "gemma-3n-e2b-it")
        self.assertEqual(gemma3n.max_context_tokens, 4_096)
        self.assertFalse(gemma3n.supports_speculative)
        self.assertFalse(gemma3n.supports_thinking)

    def test_apple_native_fallback(self):
        self.assertTrue(APPLE_NATIVE_MODEL.is_system_provided)
        self.assertEqual(APPLE_NATIVE_MODEL.size_in_bytes, 0)
        self.assertIsNone(APPLE_NATIVE_MODEL.download_url)
        self.assertEqual(APPLE_NATIVE_MODEL.llm_accel, "neuralEngine")

    def test_device_ram_compatibility(self):
        gemma4_2b = next(m for m in OFFICIAL_LITERTLM_MODELS if m.id == "gemma-4-e2b-it")
        self.assertFalse(gemma4_2b.is_device_compatible(6))
        self.assertTrue(gemma4_2b.is_device_compatible(8))
        self.assertTrue(gemma4_2b.is_device_compatible(16))

        gemma4_4b = next(m for m in OFFICIAL_LITERTLM_MODELS if m.id == "gemma-4-e4b-it")
        self.assertFalse(gemma4_4b.is_device_compatible(8))
        self.assertTrue(gemma4_4b.is_device_compatible(12))
        self.assertTrue(gemma4_4b.is_device_compatible(16))

        gemma3n_2b = next(m for m in OFFICIAL_LITERTLM_MODELS if m.id == "gemma-3n-e2b-it")
        self.assertFalse(gemma3n_2b.is_device_compatible(4))
        self.assertTrue(gemma3n_2b.is_device_compatible(6))
        self.assertTrue(gemma3n_2b.is_device_compatible(8))

    def test_no_model_weights_in_git_or_tree(self):
        script_path = REPO_ROOT / "scripts" / "assert_no_weights.sh"
        self.assertTrue(script_path.is_file(), f"Missing {script_path}")
        result = subprocess.run(
            ["bash", str(script_path), str(REPO_ROOT)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            result.returncode,
            0,
            f"assert_no_weights.sh failed:\n{result.stdout}\n{result.stderr}",
        )
        self.assertIn("SUCCESS: Directory is clean", result.stdout)

    def test_gitignore_contains_weight_patterns(self):
        gitignore_path = REPO_ROOT / ".gitignore"
        self.assertTrue(gitignore_path.is_file())
        content = gitignore_path.read_text(encoding="utf-8")
        patterns = [
            "*.litertlm",
            "*.bin",
            "*.task",
            "*.safetensors",
            "*.tflite",
            "*.onnx",
            "*.gguf",
            "*.weights",
            "*.pt",
            "*.pth",
            "models/",
        ]
        for pattern in patterns:
            self.assertIn(pattern, content, f".gitignore missing pattern '{pattern}'")


if __name__ == "__main__":
    unittest.main()
