#!/usr/bin/env python3
"""
CRITICAL SECURITY & REGRESSION TEST SUITE:
Verifies that raw audio, binary chunks, and unauthorized payloads are structurally
and deterministically blocked from exiting the device boundary.

Direct Python translation and testing of StrictTextOnlyGuard.swift and
integration testing of cloudflare-worker/test/worker.test.js.
"""

import base64
import json
import re
import subprocess
import unittest
from pathlib import Path


class SecurityViolationError(Exception):
    pass


class StrictTextOnlyGuard:
    MAX_TEXT_PAYLOAD_BYTES = 512 * 1024  # 512 KB
    BASE64_INSPECTION_THRESHOLD = 256

    FORBIDDEN_MAGIC_SIGNATURES = [
        ("RIFF/WAVE", b"RIFF"),
        ("OggS (OGG/Opus)", b"OggS"),
        ("ID3 (MP3)", b"ID3"),
        ("MP3 Sync Frame", b"\xff\xfb"),
        ("MP3 Sync Frame (Alt)", b"\xff\xf3"),
        ("MP3 Sync Frame (Alt 2)", b"\xff\xf2"),
        ("fLaC (FLAC Audio)", b"fLaC"),
        ("ftyp (M4A/MP4/AAC)", b"ftyp"),
        ("caff (Apple Core Audio)", b"caff"),
        ("FORM (AIFF Audio)", b"FORM"),
    ]

    @classmethod
    def validate_outbound_request(cls, method: str, headers: dict[str, str], body: bytes | None) -> None:
        if (method or "").upper() != "POST":
            raise SecurityViolationError("Invalid HTTP method. Must strictly be POST.")

        lower_headers = {k.lower(): v for k, v in headers.items()}
        content_type = lower_headers.get("content-type", "")
        if not content_type.startswith("application/json"):
            raise SecurityViolationError("Invalid Content-Type. Must strictly be 'application/json; charset=utf-8'.")

        for forbidden in ("audio/", "octet-stream", "multipart/", "video/"):
            if forbidden in content_type:
                raise SecurityViolationError(f"Forbidden Content-Type '{content_type}'")

        if body is None or len(body) == 0:
            raise SecurityViolationError("Outbound payload is empty.")

        cls.validate_outbound_payload(body, headers)

    @classmethod
    def validate_outbound_payload(cls, data: bytes, headers: dict[str, str] | None = None) -> None:
        if not data:
            raise SecurityViolationError("Outbound payload is empty.")

        if len(data) > cls.MAX_TEXT_PAYLOAD_BYTES:
            raise SecurityViolationError("Payload size exceeds maximum text boundary (512 KB).")

        for name, sig in cls.FORBIDDEN_MAGIC_SIGNATURES:
            if sig in data:
                raise SecurityViolationError(f"CRITICAL PRIVACY VIOLATION: Audio magic bytes detected ({name}).")

        if b"\x00" in data:
            raise SecurityViolationError("Binary null bytes (0x00) detected in outbound text stream.")

        try:
            utf8_str = data.decode("utf-8")
        except UnicodeDecodeError:
            raise SecurityViolationError("Payload contains non-UTF8 binary data.")

        try:
            root_obj = json.loads(utf8_str)
        except Exception:
            raise SecurityViolationError("Outbound payload does not conform to valid JSON object structure.")

        if not isinstance(root_obj, dict):
            raise SecurityViolationError("Outbound payload root is not a JSON dictionary.")

        cls.inspect_leaves(root_obj)

        if "text" in root_obj and isinstance(root_obj["text"], str):
            cls.validate_text_only(root_obj["text"])

    @classmethod
    def validate_text_only(cls, text: str) -> None:
        try:
            text_bytes = text.encode("utf-8")
        except UnicodeEncodeError:
            raise SecurityViolationError("Payload contains non-UTF8 binary data.")

        for name, sig in cls.FORBIDDEN_MAGIC_SIGNATURES:
            if sig in text_bytes:
                raise SecurityViolationError(f"CRITICAL PRIVACY VIOLATION: Audio magic bytes detected ({name}).")

        cls.inspect_string_for_base64_audio(text)

    @classmethod
    def inspect_leaves(cls, obj) -> None:
        if isinstance(obj, dict):
            for v in obj.values():
                cls.inspect_leaves(v)
        elif isinstance(obj, list):
            for item in obj:
                cls.inspect_leaves(item)
        elif isinstance(obj, str):
            cls.inspect_string_for_base64_audio(obj)
        elif isinstance(obj, (int, float, bool)) or obj is None:
            pass
        else:
            raise SecurityViolationError("Unrecognized or binary object type.")

    @classmethod
    def inspect_string_for_base64_audio(cls, s: str) -> None:
        b64_pattern = re.compile(r"^[A-Za-z0-9+/=]+$")
        tokens = re.split(r"\s+", s)
        for token in tokens:
            if len(token) >= cls.BASE64_INSPECTION_THRESHOLD and b64_pattern.match(token):
                prefix_len = min(len(token), 256)
                prefix_str = token[:prefix_len]
                remainder = len(prefix_str) % 4
                if remainder != 0:
                    prefix_str += "=" * (4 - remainder)

                try:
                    decoded = base64.b64decode(prefix_str)
                    for name, sig in cls.FORBIDDEN_MAGIC_SIGNATURES:
                        if sig in decoded:
                            raise SecurityViolationError(
                                f"CRITICAL PRIVACY VIOLATION: Disguised Base64-encoded audio detected ({name})."
                            )
                    if len(token) > 1024:
                        raise SecurityViolationError("High-entropy binary blob detected.")
                except SecurityViolationError:
                    raise
                except Exception:
                    pass


class TestStrictTextOnlyGuard(unittest.TestCase):
    def test_valid_text_payload_succeeds(self):
        sample = "The quarterly architecture review with the LiteRT team is scheduled for tomorrow at 2:00 PM."
        StrictTextOnlyGuard.validate_text_only(sample)

        payload = {
            "text": sample,
            "language": "en",
            "mode": "professional",
            "enableWebSearch": True,
        }
        body = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json; charset=utf-8"}

        StrictTextOnlyGuard.validate_outbound_payload(body, headers)
        StrictTextOnlyGuard.validate_outbound_request("POST", headers, body)

    def test_audio_leakage_riff_wav_rejected(self):
        wav_header = b"RIFF\x24\x00\x00\x00WAVEfmt "
        with self.assertRaises(SecurityViolationError) as ctx:
            StrictTextOnlyGuard.validate_outbound_payload(wav_header)
        self.assertIn("RIFF/WAVE", str(ctx.exception))

    def test_audio_leakage_ogg_opus_rejected(self):
        ogg_data = b"OggS\x00\x02\x00\x00"
        with self.assertRaises(SecurityViolationError) as ctx:
            StrictTextOnlyGuard.validate_outbound_payload(ogg_data)
        self.assertIn("OggS", str(ctx.exception))

    def test_audio_leakage_mp3_signatures_rejected(self):
        # ID3
        id3_data = b"ID3\x03\x00\x00\x00"
        with self.assertRaises(SecurityViolationError) as ctx:
            StrictTextOnlyGuard.validate_outbound_payload(id3_data)
        self.assertIn("ID3", str(ctx.exception))

        # Sync frame
        sync_data = b"\xff\xfb\x90\x64"
        with self.assertRaises(SecurityViolationError) as ctx:
            StrictTextOnlyGuard.validate_outbound_payload(sync_data)
        self.assertIn("Sync Frame", str(ctx.exception))

    def test_audio_leakage_flac_rejected(self):
        flac_data = b"fLaC\x00\x00\x00\x22"
        with self.assertRaises(SecurityViolationError) as ctx:
            StrictTextOnlyGuard.validate_outbound_payload(flac_data)
        self.assertIn("FLAC", str(ctx.exception))

    def test_audio_leakage_m4a_ftyp_rejected(self):
        ftyp_data = b"\x00\x00\x00\x20ftypM4A "
        with self.assertRaises(SecurityViolationError) as ctx:
            StrictTextOnlyGuard.validate_outbound_payload(ftyp_data)
        self.assertIn("ftyp", str(ctx.exception))

    def test_audio_leakage_caff_rejected(self):
        caf_data = b"caff\x00\x01\x00\x00"
        with self.assertRaises(SecurityViolationError) as ctx:
            StrictTextOnlyGuard.validate_outbound_payload(caf_data)
        self.assertIn("caff", str(ctx.exception))

    def test_audio_leakage_form_aiff_rejected(self):
        form_data = b"FORM\x00\x01\x00\x00AIFF"
        with self.assertRaises(SecurityViolationError) as ctx:
            StrictTextOnlyGuard.validate_outbound_payload(form_data)
        self.assertIn("FORM", str(ctx.exception))

    def test_disguised_base64_audio_chunk_rejected(self):
        raw_audio = b"RIFF\x24\x00\x00\x00WAVE" + b"\x7f" * 250
        b64_audio = base64.b64encode(raw_audio).decode("ascii")

        malicious_payload = json.dumps({"text": f"Meeting notes: {b64_audio}"}).encode("utf-8")
        with self.assertRaises(SecurityViolationError) as ctx:
            StrictTextOnlyGuard.validate_outbound_payload(malicious_payload)
        self.assertTrue(
            "Base64-encoded audio" in str(ctx.exception) or "Audio magic bytes" in str(ctx.exception)
        )

    def test_high_entropy_binary_blob_rejected(self):
        import os
        random_blob = os.urandom(800)
        b64_blob = base64.b64encode(random_blob).decode("ascii")
        self.assertGreater(len(b64_blob), 1024)

        payload = json.dumps({"text": b64_blob}).encode("utf-8")
        with self.assertRaises(SecurityViolationError) as ctx:
            StrictTextOnlyGuard.validate_outbound_payload(payload)
        self.assertTrue(
            "High-entropy" in str(ctx.exception)
            or "Base64" in str(ctx.exception)
            or "Audio magic bytes" in str(ctx.exception)
        )

    def test_binary_null_bytes_rejected(self):
        raw = json.dumps({"text": "Hello world"}).encode("utf-8") + b"\x00"
        with self.assertRaises(SecurityViolationError) as ctx:
            StrictTextOnlyGuard.validate_outbound_payload(raw)
        self.assertIn("Binary null bytes", str(ctx.exception))

    def test_invalid_content_type_rejected(self):
        body = json.dumps({"text": "Hello world"}).encode("utf-8")

        for bad_type in [
            "audio/wav",
            "audio/mpeg",
            "application/octet-stream",
            "multipart/form-data; boundary=xyz",
            "text/plain",
        ]:
            with self.assertRaises(SecurityViolationError):
                StrictTextOnlyGuard.validate_outbound_request("POST", {"Content-Type": bad_type}, body)

    def test_invalid_http_method_rejected(self):
        body = json.dumps({"text": "Hello world"}).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        for method in ["GET", "PUT", "DELETE", "PATCH", "HEAD"]:
            with self.assertRaises(SecurityViolationError):
                StrictTextOnlyGuard.validate_outbound_request(method, headers, body)

    def test_excessive_payload_size_rejected(self):
        huge_text = "A" * (600 * 1024)
        huge_data = json.dumps({"text": huge_text}).encode("utf-8")
        with self.assertRaises(SecurityViolationError) as ctx:
            StrictTextOnlyGuard.validate_outbound_payload(huge_data)
        self.assertIn("512 KB", str(ctx.exception))

    def test_cloudflare_worker_npm_suite(self):
        """Executes the Cloudflare Worker test suite via npm test in Linux CI."""
        worker_dir = Path(__file__).resolve().parent.parent / "cloudflare-worker"
        self.assertTrue(worker_dir.exists(), f"Directory not found: {worker_dir}")

        res = subprocess.run(
            ["npm", "test"],
            cwd=str(worker_dir),
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            res.returncode,
            0,
            f"cloudflare-worker npm test failed with code {res.returncode}:\n{res.stdout}\n{res.stderr}",
        )
        output = res.stdout.lower() + res.stderr.lower()
        self.assertRegex(output, r"# tests \d+")
        self.assertIn("# fail 0", output)


if __name__ == "__main__":
    unittest.main()
