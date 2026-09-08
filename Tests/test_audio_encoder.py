#!/usr/bin/env python3
"""
Audio Tests for Edge Eloquent.
Validates:
- Canonical 44-byte RIFF WAV header construction
- 16 kHz sample rate, 1 channel (mono), 16-bit Linear PCM Little-Endian
- Byte rate (32,000 bytes/sec) and block align (2 bytes)
- 15-second audio window calculations (240,000 samples, 480,000 bytes)
- Float32 to Int16 quantization and overshoot/undershoot clamping
- Corrupted buffer and invalid header rejection
"""

import unittest
import struct
import math


class WAVEncoder:
    """Python reference implementation of WAVEncoder conforming to Sources/EdgeEloquent/Audio/WAVEncoder.swift."""

    HEADER_SIZE = 44

    @staticmethod
    def float_to_int16(sample: float) -> int:
        clamped = max(-1.0, min(1.0, sample))
        if clamped >= 1.0:
            return 32767
        elif clamped <= -1.0:
            return -32767
        else:
            return int(clamped * 32767.0)

    @classmethod
    def create_wav_header(
        cls,
        data_size: int,
        sample_rate: int = 16000,
        channels: int = 1,
        bits_per_sample: int = 16,
    ) -> bytes:
        bytes_per_sample = bits_per_sample // 8
        byte_rate = sample_rate * channels * bytes_per_sample
        block_align = channels * bytes_per_sample
        file_size = 36 + data_size

        header = bytearray(cls.HEADER_SIZE)
        # RIFF descriptor
        header[0:4] = b"RIFF"
        struct.pack_into("<I", header, 4, file_size)
        header[8:12] = b"WAVE"

        # fmt chunk
        header[12:16] = b"fmt "
        struct.pack_into("<I", header, 16, 16)  # Subchunk1Size = 16
        struct.pack_into("<H", header, 20, 1)   # AudioFormat = 1 (PCM)
        struct.pack_into("<H", header, 22, channels)
        struct.pack_into("<I", header, 24, sample_rate)
        struct.pack_into("<I", header, 28, byte_rate)
        struct.pack_into("<H", header, 32, block_align)
        struct.pack_into("<H", header, 34, bits_per_sample)

        # data chunk
        header[36:40] = b"data"
        struct.pack_into("<I", header, 40, data_size)

        return bytes(header)

    @classmethod
    def encode(cls, samples: list[float], sample_rate: int = 16000) -> bytes:
        data_size = len(samples) * 2
        header = cls.create_wav_header(data_size=data_size, sample_rate=sample_rate)
        pcm_bytes = bytearray(data_size)
        for i, s in enumerate(samples):
            int16_val = cls.float_to_int16(s)
            struct.pack_into("<h", pcm_bytes, i * 2, int16_val)
        return header + bytes(pcm_bytes)

    @classmethod
    def validate_wav_header(cls, data: bytes) -> dict:
        if len(data) < cls.HEADER_SIZE:
            return {"is_valid": False, "error": f"Data size ({len(data)}) < 44"}

        if data[0:4] != b"RIFF":
            return {"is_valid": False, "error": "Missing 'RIFF' marker"}

        (chunk_size,) = struct.unpack_from("<I", data, 4)
        expected_chunk_size = len(data) - 8
        if chunk_size != expected_chunk_size:
            return {"is_valid": False, "error": f"ChunkSize mismatch ({chunk_size} != {expected_chunk_size})"}

        if data[8:12] != b"WAVE":
            return {"is_valid": False, "error": "Missing 'WAVE' marker"}

        if data[12:16] != b"fmt ":
            return {"is_valid": False, "error": "Missing 'fmt ' marker"}

        (subchunk1_size,) = struct.unpack_from("<I", data, 16)
        if subchunk1_size != 16:
            return {"is_valid": False, "error": f"Subchunk1Size ({subchunk1_size}) != 16"}

        (audio_format,) = struct.unpack_from("<H", data, 20)
        if audio_format != 1:
            return {"is_valid": False, "error": f"AudioFormat ({audio_format}) != 1 (PCM)"}

        (channels,) = struct.unpack_from("<H", data, 22)
        (sample_rate,) = struct.unpack_from("<I", data, 24)
        (byte_rate,) = struct.unpack_from("<I", data, 28)
        (block_align,) = struct.unpack_from("<H", data, 32)
        (bits_per_sample,) = struct.unpack_from("<H", data, 34)

        expected_block_align = channels * (bits_per_sample // 8)
        if block_align != expected_block_align:
            return {"is_valid": False, "error": f"Invalid BlockAlign ({block_align} != {expected_block_align})"}

        expected_byte_rate = sample_rate * expected_block_align
        if byte_rate != expected_byte_rate:
            return {"is_valid": False, "error": f"Invalid ByteRate ({byte_rate} != {expected_byte_rate})"}

        if data[36:40] != b"data":
            return {"is_valid": False, "error": "Missing 'data' marker"}

        (subchunk2_size,) = struct.unpack_from("<I", data, 40)
        expected_data_size = len(data) - 44
        if subchunk2_size != expected_data_size:
            return {"is_valid": False, "error": f"Subchunk2Size mismatch ({subchunk2_size} != {expected_data_size})"}

        return {
            "is_valid": True,
            "sample_rate": sample_rate,
            "channels": channels,
            "bits_per_sample": bits_per_sample,
            "data_byte_size": subchunk2_size,
            "error": None,
        }


class TestWAVEncoder(unittest.TestCase):

    def test_canonical_magic_bytes(self):
        wav = WAVEncoder.encode([], sample_rate=16000)
        self.assertEqual(len(wav), 44, "Empty WAV must be exactly 44 bytes")
        self.assertEqual(wav[0:4], b"RIFF")
        self.assertEqual(wav[8:12], b"WAVE")
        self.assertEqual(wav[12:16], b"fmt ")
        self.assertEqual(wav[36:40], b"data")

    def test_little_endian_fields(self):
        samples = [0.1] * 100
        wav = WAVEncoder.encode(samples, sample_rate=16000)

        subchunk1_size = struct.unpack_from("<I", wav, 16)[0]
        self.assertEqual(subchunk1_size, 16)

        audio_format = struct.unpack_from("<H", wav, 20)[0]
        self.assertEqual(audio_format, 1, "Audio format must be 1 (PCM)")

        channels = struct.unpack_from("<H", wav, 22)[0]
        self.assertEqual(channels, 1, "Channel count must be 1 (Mono)")

        sample_rate = struct.unpack_from("<I", wav, 24)[0]
        self.assertEqual(sample_rate, 16000)

        byte_rate = struct.unpack_from("<I", wav, 28)[0]
        self.assertEqual(byte_rate, 32000, "Byte rate = 16000 * 1 * 2 = 32000")

        block_align = struct.unpack_from("<H", wav, 32)[0]
        self.assertEqual(block_align, 2, "Block align = 1 * (16 / 8) = 2")

        bits_per_sample = struct.unpack_from("<H", wav, 34)[0]
        self.assertEqual(bits_per_sample, 16)

    def test_15_second_window_exact_size_calculations(self):
        sample_rate = 16000
        duration_sec = 15.0
        expected_samples = int(sample_rate * duration_sec)  # 240,000
        self.assertEqual(expected_samples, 240_000)

        expected_data_size = expected_samples * 2  # 480,000 bytes
        self.assertEqual(expected_data_size, 480_000)

        expected_chunk_size = 36 + expected_data_size  # 480,036
        expected_total_file_size = 44 + expected_data_size  # 480,044

        samples = [0.0] * expected_samples
        wav = WAVEncoder.encode(samples, sample_rate=sample_rate)

        self.assertEqual(len(wav), expected_total_file_size)

        chunk_size = struct.unpack_from("<I", wav, 4)[0]
        self.assertEqual(chunk_size, expected_chunk_size)

        subchunk2_size = struct.unpack_from("<I", wav, 40)[0]
        self.assertEqual(subchunk2_size, expected_data_size)

        validation = WAVEncoder.validate_wav_header(wav)
        self.assertTrue(validation["is_valid"])
        self.assertEqual(validation["sample_rate"], 16000)
        self.assertEqual(validation["channels"], 1)
        self.assertEqual(validation["bits_per_sample"], 16)
        self.assertEqual(validation["data_byte_size"], 480_000)
        self.assertIsNone(validation["error"])

    def test_float_to_int16_clamping_and_quantization(self):
        self.assertEqual(WAVEncoder.float_to_int16(0.0), 0)
        self.assertEqual(WAVEncoder.float_to_int16(1.0), 32767)
        self.assertEqual(WAVEncoder.float_to_int16(-1.0), -32767)

        # Overshoot / undershoot clamping
        self.assertEqual(WAVEncoder.float_to_int16(1.5), 32767)
        self.assertEqual(WAVEncoder.float_to_int16(100.0), 32767)
        self.assertEqual(WAVEncoder.float_to_int16(-1.5), -32767)
        self.assertEqual(WAVEncoder.float_to_int16(-50.0), -32767)

        # Mid-scale values
        self.assertEqual(WAVEncoder.float_to_int16(0.5), 16383)
        self.assertEqual(WAVEncoder.float_to_int16(-0.5), -16383)

    def test_payload_integrity(self):
        samples = [0.0, 1.0, -1.0, 0.5]
        wav = WAVEncoder.encode(samples, sample_rate=16000)
        self.assertEqual(len(wav), 44 + 4 * 2)

        pcm_bytes = wav[44:]
        int16_vals = struct.unpack(f"<{len(samples)}h", pcm_bytes)
        self.assertEqual(int16_vals, (0, 32767, -32767, 16383))

    def test_corrupted_headers_rejection(self):
        # 1. Short buffer
        short_res = WAVEncoder.validate_wav_header(b"RIFF")
        self.assertFalse(short_res["is_valid"])

        # 2. Corrupt RIFF marker
        valid = bytearray(WAVEncoder.encode([0.1, 0.2], sample_rate=16000))
        bad_riff = bytearray(valid)
        bad_riff[0] = 0x00
        res = WAVEncoder.validate_wav_header(bytes(bad_riff))
        self.assertFalse(res["is_valid"])
        self.assertIn("RIFF", res["error"])

        # 3. Corrupt WAVE marker
        bad_wave = bytearray(valid)
        bad_wave[8] = 0x00
        res = WAVEncoder.validate_wav_header(bytes(bad_wave))
        self.assertFalse(res["is_valid"])
        self.assertIn("WAVE", res["error"])


if __name__ == "__main__":
    unittest.main()
