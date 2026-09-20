from __future__ import annotations

from dataclasses import fields
from pathlib import Path
import sqlite3
import unittest

from tools.reader_core import DEFAULT_MANIFEST, QuranReader, ReaderError

ROOT = Path(__file__).resolve().parents[1]


class ReaderCoreTests(unittest.TestCase):
    def test_reader_projection_exposes_original_text_not_search_lanes(self) -> None:
        with QuranReader.open(ROOT) as reader:
            ayah = reader.get_ayah(1, 1)

        manifest_path = ROOT / DEFAULT_MANIFEST
        import json

        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        with sqlite3.connect(ROOT / manifest["artifact_path"]) as connection:
            expected = connection.execute(
                "SELECT original_text FROM quran_ayah WHERE surah = 1 AND ayah = 1"
            ).fetchone()[0]

        self.assertEqual(ayah.ayah_id, "qa:001:001")
        self.assertEqual(ayah.original_text, expected)
        self.assertEqual(
            {field.name for field in fields(ayah)},
            {"ayah_id", "surah", "ayah", "original_text", "source_assertion_id"},
        )

    def test_surah_navigation_uses_stable_coordinates(self) -> None:
        with QuranReader.open(ROOT) as reader:
            rows = reader.list_surah(1)

        self.assertEqual(len(rows), 7)
        self.assertEqual(rows[0].ayah_id, "qa:001:001")
        self.assertEqual(rows[-1].ayah_id, "qa:001:007")
        self.assertEqual([row.ayah for row in rows], list(range(1, 8)))

    def test_current_ayah_only_pack_never_manufactures_word_tokens(self) -> None:
        with QuranReader.open(ROOT) as reader:
            self.assertEqual(reader.word_layer_status, "absent")
            self.assertFalse(reader.word_tap_ready)
            self.assertEqual(reader.tokens_for_ayah(1, 1), ())

    def test_reader_connection_is_query_only(self) -> None:
        with QuranReader.open(ROOT) as reader:
            with self.assertRaises(sqlite3.OperationalError):
                reader._connection.execute(
                    "UPDATE quran_ayah SET original_text = original_text WHERE surah = 1 AND ayah = 1"
                )

    def test_invalid_or_missing_coordinates_fail_closed(self) -> None:
        with QuranReader.open(ROOT) as reader:
            for surah, ayah in ((0, 1), (115, 1), (1, 0), (2, 999)):
                with self.subTest(surah=surah, ayah=ayah):
                    with self.assertRaises(ReaderError):
                        reader.get_ayah(surah, ayah)


if __name__ == "__main__":
    unittest.main()
