from __future__ import annotations

from pathlib import Path
import shutil
import tempfile
import unittest

from tools.verify_quranenc_snapshot import (
    SNAPSHOT_RELATIVE,
    SnapshotError,
    verify_snapshot,
)


class QuranEncSnapshotTests(unittest.TestCase):
    def test_committed_review_snapshot_verifies_offline(self):
        root = Path(__file__).resolve().parents[1]
        result = verify_snapshot(root)
        self.assertEqual(114, result["sura_count"])
        self.assertEqual(6236, result["record_count"])
        self.assertEqual("captured-unreviewed", result["promotion_status"])
        self.assertEqual(119, result["ledger_members"])

    def test_tampered_surah_fails_before_content_can_be_used(self):
        source_root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            destination = root / SNAPSHOT_RELATIVE
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(source_root / SNAPSHOT_RELATIVE, destination)
            target = destination / "raw/suras/001.json"
            target.write_bytes(target.read_bytes() + b"\n")
            with self.assertRaisesRegex(
                SnapshotError, "checksum-set member SHA-256 mismatch"
            ):
                verify_snapshot(root)


if __name__ == "__main__":
    unittest.main()
