#!/usr/bin/env python3
"""
Unit and regression test suite for TranscriptionRecord and TranscriptionHistoryStore.
Mirrors Sources/EdgeEloquent/History and Tests/EdgeEloquentTests/HistoryStoreTests.swift.
"""

from __future__ import annotations

import dataclasses
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid


@dataclasses.dataclass
class TranscriptionRecord:
    clean_transcript: str
    final_text: str
    id: str = dataclasses.field(default_factory=lambda: str(uuid.uuid4()))
    date: str = dataclasses.field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    model_used: str = ""
    duration_seconds: float = 0.0
    is_enhanced: bool = False

    @property
    def duration_label(self) -> str:
        total_seconds = max(0, int(round(self.duration_seconds)))
        if total_seconds < 60:
            return f"{total_seconds}s"
        minutes = total_seconds // 60
        seconds = total_seconds % 60
        return f"{minutes}m {seconds:02d}s"

    @property
    def display_text(self) -> str:
        trimmed = self.final_text.strip()
        return self.clean_transcript if not trimmed else self.final_text

    def with_final_text(self, new_text: str, is_enhanced: bool | None = None) -> TranscriptionRecord:
        copy_record = dataclasses.replace(self, final_text=new_text)
        if is_enhanced is not None:
            copy_record.is_enhanced = is_enhanced
        return copy_record

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "date": self.date,
            "cleanTranscript": self.clean_transcript,
            "finalText": self.final_text,
            "modelUsed": self.model_used,
            "durationSeconds": self.duration_seconds,
            "isEnhanced": self.is_enhanced,
        }

    @classmethod
    def from_dict(cls, data: dict) -> TranscriptionRecord:
        return cls(
            id=str(data.get("id", uuid.uuid4())),
            date=str(data.get("date", datetime.now(timezone.utc).isoformat())),
            clean_transcript=str(data.get("cleanTranscript", "")),
            final_text=str(data.get("finalText", "")),
            model_used=str(data.get("modelUsed", "")),
            duration_seconds=float(data.get("durationSeconds", 0.0)),
            is_enhanced=bool(data.get("isEnhanced", False)),
        )


class TranscriptionHistoryStore:
    DATABASE_FILENAME = "transcription_history.json"
    APPLICATION_SUBDIRECTORY = "EdgeEloquent"

    def __init__(self, file_path: Path):
        self.file_path = file_path
        self.records: list[TranscriptionRecord] = []
        self.load_history()

    def load_history(self) -> list[TranscriptionRecord]:
        self.records = self.read(self.file_path)
        return self.records

    def list_records(self) -> list[TranscriptionRecord]:
        return list(self.records)

    def get_record(self, record_id: str) -> TranscriptionRecord | None:
        for r in self.records:
            if r.id == record_id:
                return r
        return None

    def save_record(self, record: TranscriptionRecord) -> None:
        for idx, r in enumerate(self.records):
            if r.id == record.id:
                self.records[idx] = record
                self.persist()
                return

        self.records.insert(0, record)
        self.persist()

    def delete_record(self, record_id: str) -> None:
        orig_count = len(self.records)
        self.records = [r for r in self.records if r.id != record_id]
        if len(self.records) != orig_count:
            self.persist()

    def delete_records(self, record_ids: set[str]) -> None:
        orig_count = len(self.records)
        self.records = [r for r in self.records if r.id not in record_ids]
        if len(self.records) != orig_count:
            self.persist()

    def clear_all(self) -> None:
        if not self.records:
            return
        self.records.clear()
        self.persist()

    def persist(self) -> None:
        self.write(self.records, self.file_path)

    @classmethod
    def read(cls, file_path: Path) -> list[TranscriptionRecord]:
        if not file_path.exists():
            return []
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if not isinstance(data, list):
                return []
            return [TranscriptionRecord.from_dict(item) for item in data if isinstance(item, dict)]
        except Exception:
            # Corrupted or unreadable file: return empty without crashing
            return []

    @classmethod
    def write(cls, records: list[TranscriptionRecord], file_path: Path) -> None:
        file_path.parent.mkdir(parents=True, exist_ok=True)
        temp_file = file_path.with_suffix(".tmp." + uuid.uuid4().hex)
        try:
            payload = [r.to_dict() for r in records]
            with open(temp_file, "w", encoding="utf-8") as f:
                json.dump(payload, f, indent=2, ensure_ascii=False)
            os.replace(temp_file, file_path)
        except Exception:
            if temp_file.exists():
                try:
                    temp_file.unlink()
                except Exception:
                    pass
            raise


class TestTranscriptionHistoryStore(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.test_dir = Path(self.temp_dir.name)
        self.test_file = self.test_dir / "EdgeEloquent" / "transcription_history.json"

    def tearDown(self):
        self.temp_dir.cleanup()

    def make_store(self) -> TranscriptionHistoryStore:
        return TranscriptionHistoryStore(self.test_file)

    def sample_record(
        self,
        clean: str = "Hello world",
        final: str = "Hello, world!",
        rec_id: str | None = None,
        duration: float = 5.5,
        is_enhanced: bool = True,
    ) -> TranscriptionRecord:
        return TranscriptionRecord(
            id=rec_id or str(uuid.uuid4()),
            clean_transcript=clean,
            final_text=final,
            model_used="gemma-3n-E2B-it",
            duration_seconds=duration,
            is_enhanced=is_enhanced,
        )

    # MARK: - Model Tests

    def test_record_initialization_defaults(self):
        rec = TranscriptionRecord(clean_transcript="Raw", final_text="Polished")
        self.assertTrue(len(rec.id) > 0)
        self.assertEqual(rec.clean_transcript, "Raw")
        self.assertEqual(rec.final_text, "Polished")
        self.assertEqual(rec.model_used, "")
        self.assertEqual(rec.duration_seconds, 0.0)
        self.assertFalse(rec.is_enhanced)

    def test_record_convenience_helpers(self):
        r0 = self.sample_record(duration=0.0)
        self.assertEqual(r0.duration_label, "0s")

        r42 = self.sample_record(duration=42.4)
        self.assertEqual(r42.duration_label, "42s")

        r65 = self.sample_record(duration=65.0)
        self.assertEqual(r65.duration_label, "1m 05s")

        r605 = self.sample_record(duration=605.0)
        self.assertEqual(r605.duration_label, "10m 05s")

        # Display text helper
        r_final = self.sample_record(clean="raw text", final="polished text")
        self.assertEqual(r_final.display_text, "polished text")

        r_empty_final = self.sample_record(clean="raw text", final="")
        self.assertEqual(r_empty_final.display_text, "raw text")

        # with_final_text
        updated = r_empty_final.with_final_text("new final", is_enhanced=True)
        self.assertEqual(updated.final_text, "new final")
        self.assertTrue(updated.is_enhanced)
        self.assertEqual(updated.id, r_empty_final.id)

    def test_record_codable_roundtrip(self):
        original = self.sample_record()
        serialized = json.dumps(original.to_dict())
        data = json.loads(serialized)
        decoded = TranscriptionRecord.from_dict(data)

        self.assertEqual(decoded.id, original.id)
        self.assertEqual(decoded.clean_transcript, original.clean_transcript)
        self.assertEqual(decoded.final_text, original.final_text)
        self.assertEqual(decoded.model_used, original.model_used)
        self.assertEqual(decoded.duration_seconds, original.duration_seconds)
        self.assertEqual(decoded.is_enhanced, original.is_enhanced)
        self.assertEqual(decoded.date, original.date)

    # MARK: - Store CRUD Tests

    def test_initial_state_is_empty_when_no_file(self):
        store = self.make_store()
        self.assertEqual(len(store.records), 0)
        self.assertEqual(len(store.list_records()), 0)
        self.assertIsNone(store.get_record("non-existent-id"))
        self.assertFalse(self.test_file.exists())

    def test_save_record_persists_to_memory_and_disk(self):
        store = self.make_store()
        rec = self.sample_record()
        store.save_record(rec)

        self.assertEqual(len(store.records), 1)
        self.assertEqual(store.records[0].id, rec.id)
        self.assertEqual(store.get_record(rec.id).final_text, rec.final_text)

        self.assertTrue(self.test_file.exists())
        disk_records = TranscriptionHistoryStore.read(self.test_file)
        self.assertEqual(len(disk_records), 1)
        self.assertEqual(disk_records[0].id, rec.id)

    def test_save_record_orders_newest_first(self):
        store = self.make_store()
        r1 = self.sample_record(clean="First")
        r2 = self.sample_record(clean="Second")
        r3 = self.sample_record(clean="Third")

        store.save_record(r1)
        store.save_record(r2)
        store.save_record(r3)

        self.assertEqual([r.clean_transcript for r in store.records], ["Third", "Second", "First"])
        disk_records = TranscriptionHistoryStore.read(self.test_file)
        self.assertEqual([r.clean_transcript for r in disk_records], ["Third", "Second", "First"])

    def test_save_record_updates_in_place(self):
        store = self.make_store()
        fixed_id = str(uuid.uuid4())
        original = self.sample_record(clean="Original", final="Original", rec_id=fixed_id, is_enhanced=False)
        later = self.sample_record(clean="Another")

        store.save_record(original)
        store.save_record(later)
        self.assertEqual(len(store.records), 2)

        # Update original record
        updated = self.sample_record(clean="Original", final="Polished", rec_id=fixed_id, is_enhanced=True)
        store.save_record(updated)

        self.assertEqual(len(store.records), 2)
        found = store.get_record(fixed_id)
        self.assertIsNotNone(found)
        self.assertEqual(found.final_text, "Polished")
        self.assertTrue(found.is_enhanced)

        disk_records = TranscriptionHistoryStore.read(self.test_file)
        disk_found = next(r for r in disk_records if r.id == fixed_id)
        self.assertEqual(disk_found.final_text, "Polished")

    def test_persistence_survives_relaunch(self):
        store1 = self.make_store()
        r1 = self.sample_record(clean="One", duration=1.0)
        r2 = self.sample_record(clean="Two", duration=2.0)

        store1.save_record(r1)
        store1.save_record(r2)

        # Re-instantiate from same file path
        store2 = self.make_store()
        self.assertEqual(len(store2.records), 2)
        self.assertEqual([r.clean_transcript for r in store2.records], ["Two", "One"])
        self.assertEqual(store2.records[0].duration_seconds, 2.0)
        self.assertEqual(store2.records[1].duration_seconds, 1.0)

    def test_delete_record_by_id(self):
        store = self.make_store()
        r1 = self.sample_record(clean="Record 1")
        r2 = self.sample_record(clean="Record 2")
        r3 = self.sample_record(clean="Record 3")

        store.save_record(r1)
        store.save_record(r2)
        store.save_record(r3)
        self.assertEqual(len(store.records), 3)

        store.delete_record(r2.id)
        self.assertEqual(len(store.records), 2)
        self.assertIsNone(store.get_record(r2.id))
        self.assertEqual([r.clean_transcript for r in store.records], ["Record 3", "Record 1"])

        disk_records = TranscriptionHistoryStore.read(self.test_file)
        self.assertEqual([r.clean_transcript for r in disk_records], ["Record 3", "Record 1"])

    def test_delete_non_existent_id_is_noop(self):
        store = self.make_store()
        r = self.sample_record()
        store.save_record(r)

        store.delete_record("some-non-existent-uuid")
        self.assertEqual(len(store.records), 1)
        self.assertEqual(store.records[0].id, r.id)

    def test_delete_multiple_records(self):
        store = self.make_store()
        r1 = self.sample_record(clean="A")
        r2 = self.sample_record(clean="B")
        r3 = self.sample_record(clean="C")

        store.save_record(r1)
        store.save_record(r2)
        store.save_record(r3)

        store.delete_records({r1.id, r3.id})
        self.assertEqual(len(store.records), 1)
        self.assertEqual(store.records[0].clean_transcript, "B")

        disk_records = TranscriptionHistoryStore.read(self.test_file)
        self.assertEqual(len(disk_records), 1)
        self.assertEqual(disk_records[0].clean_transcript, "B")

    def test_clear_all_empties_store_and_file(self):
        store = self.make_store()
        store.save_record(self.sample_record(clean="Item 1"))
        store.save_record(self.sample_record(clean="Item 2"))
        self.assertEqual(len(store.records), 2)

        store.clear_all()
        self.assertTrue(len(store.records) == 0)
        disk_records = TranscriptionHistoryStore.read(self.test_file)
        self.assertEqual(len(disk_records), 0)

    def test_corrupted_file_recovery(self):
        self.test_file.parent.mkdir(parents=True, exist_ok=True)
        with open(self.test_file, "w", encoding="utf-8") as f:
            f.write("Corrupted non-JSON payload {{{")

        store = self.make_store()
        self.assertEqual(len(store.records), 0)

        # Saving a new record overwrites corrupt file with valid JSON
        valid = self.sample_record(clean="Recovered")
        store.save_record(valid)
        self.assertEqual(len(store.records), 1)

        disk_records = TranscriptionHistoryStore.read(self.test_file)
        self.assertEqual(len(disk_records), 1)
        self.assertEqual(disk_records[0].clean_transcript, "Recovered")

    def test_default_file_path_structure(self):
        self.assertEqual(TranscriptionHistoryStore.DATABASE_FILENAME, "transcription_history.json")
        self.assertEqual(TranscriptionHistoryStore.APPLICATION_SUBDIRECTORY, "EdgeEloquent")


if __name__ == "__main__":
    unittest.main()
