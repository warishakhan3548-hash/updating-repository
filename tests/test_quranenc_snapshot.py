from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from tools.quran_core import EXPECTED_AYAH_COUNTS
from tools.quranenc_snapshot import (
    FetchResult,
    SnapshotError,
    acquire_snapshot,
    translation_metadata,
    validate_sura_response,
)


class FakeQuranEnc:
    def __init__(self, *, before_version: str = "1.0.0", after_version: str | None = None):
        self.before_version = before_version
        self.after_version = after_version or before_version
        self.list_calls = 0

    @staticmethod
    def _result(url: str, payload: bytes, content_type: str) -> FetchResult:
        return FetchResult(url, url, payload, content_type)

    def __call__(self, url: str) -> FetchResult:
        if "translations/list" in url:
            self.list_calls += 1
            version = self.before_version if self.list_calls == 1 else self.after_version
            payload = {
                "result": [
                    {
                        "key": "arabic_seraj",
                        "language_iso_code": "ar",
                        "version": version,
                        "last_update": "2017-02-15",
                    }
                ]
            }
            return self._result(url, json.dumps(payload).encode(), "application/json")
        if url.endswith("/home/api"):
            return self._result(
                url,
                b"<html><body><h1>Terms and Policies</h1></body></html>",
                "text/html",
            )
        sura = int(url.rsplit("/", 1)[1])
        rows = [
            {
                "sura": str(sura),
                "aya": str(aya),
                "translation": "",
                "footnotes": "",
            }
            for aya in range(1, EXPECTED_AYAH_COUNTS[sura - 1] + 1)
        ]
        return self._result(
            url,
            json.dumps({"result": rows}, separators=(",", ":")).encode(),
            "application/json",
        )


class QuranEncSnapshotTests(unittest.TestCase):
    def test_translation_metadata_accepts_documented_result_shape(self):
        payload = json.dumps(
            {
                "result": [
                    {
                        "key": "arabic_seraj",
                        "version": "1.0.0",
                        "last_update": "2017-02-15",
                    }
                ]
            }
        ).encode()
        self.assertEqual(
            {
                "key": "arabic_seraj",
                "version": "1.0.0",
                "last_update": "2017-02-15",
            },
            translation_metadata(payload, "arabic_seraj"),
        )

    def test_validate_sura_requires_complete_coordinates(self):
        rows = [
            {"sura": "1", "aya": str(aya), "translation": "", "footnotes": ""}
            for aya in range(1, 8)
        ]
        rows.pop(3)
        with self.assertRaisesRegex(SnapshotError, "row count mismatch"):
            validate_sura_response(json.dumps({"result": rows}).encode(), 1)

    def test_acquisition_preserves_all_raw_responses_without_promotion(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "quranenc-arabic-seraj-1.0.0"
            acquire_snapshot(
                output,
                expected_version="1.0.0",
                fetch=FakeQuranEnc(),
                retrieved_at=datetime(2026, 9, 20, 18, 30, tzinfo=timezone.utc),
            )
            manifest = json.loads(
                (output / "snapshot_manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual("1.0.0", manifest["version"])
            self.assertEqual(6236, manifest["coordinate_count"])
            self.assertEqual(114, manifest["surah_count"])
            self.assertEqual(
                "requires-human-review-before-vault-promotion",
                manifest["licence_review_state"],
            )
            self.assertEqual(117, len(manifest["files"]))
            self.assertTrue((output / "raw" / "sura-114.json").is_file())
            self.assertTrue((output / "raw" / "TERMS_SOURCE.html").is_file())
            self.assertTrue((output / "sha256.txt").is_file())

    def test_version_drift_discards_partial_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "snapshot"
            with self.assertRaisesRegex(SnapshotError, "changed during acquisition"):
                acquire_snapshot(
                    output,
                    expected_version="1.0.0",
                    fetch=FakeQuranEnc(after_version="1.0.1"),
                    retrieved_at=datetime(2026, 9, 20, tzinfo=timezone.utc),
                )
            self.assertFalse(output.exists())
            self.assertFalse(list(Path(tmp).glob(".snapshot.partial-*")))

    def test_wrong_expected_version_fails_before_sura_fetch(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "snapshot"
            fake = FakeQuranEnc(before_version="1.0.1")
            with self.assertRaisesRegex(SnapshotError, "expected '1.0.0'"):
                acquire_snapshot(
                    output,
                    expected_version="1.0.0",
                    fetch=fake,
                    retrieved_at=datetime(2026, 9, 20, tzinfo=timezone.utc),
                )
            self.assertEqual(1, fake.list_calls)
            self.assertFalse(output.exists())

    def test_existing_output_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "snapshot"
            output.mkdir()
            marker = output / "keep.txt"
            marker.write_text("keep", encoding="utf-8")
            with self.assertRaisesRegex(SnapshotError, "already exists"):
                acquire_snapshot(
                    output,
                    expected_version="1.0.0",
                    fetch=FakeQuranEnc(),
                    retrieved_at=datetime(2026, 9, 20, tzinfo=timezone.utc),
                )
            self.assertEqual("keep", marker.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
