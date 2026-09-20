import sqlite3
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class SqlSchemaTests(unittest.TestCase):
    def load(self, name: str) -> sqlite3.Connection:
        connection = sqlite3.connect(":memory:")
        connection.executescript((ROOT / "schemas" / name).read_text(encoding="utf-8"))
        return connection

    def test_quran_display_and_search_fields_are_separate(self):
        connection = self.load("content_v1.sql")
        columns = {
            row[1] for row in connection.execute("PRAGMA table_info(quran_ayah)")
        }
        self.assertIn("original_text", columns)
        self.assertIn("search_unicode", columns)
        self.assertIn("search_diacritic_free", columns)
        connection.close()

    def test_hadith_matn_and_isnad_search_fields_are_separate(self):
        connection = self.load("content_v1.sql")
        columns = {
            row[1] for row in connection.execute("PRAGMA table_info(hadith_record)")
        }
        self.assertIn("matn_original", columns)
        self.assertIn("isnad_original", columns)
        self.assertIn("search_matn_diacritic_free", columns)
        self.assertIn("search_isnad_diacritic_free", columns)
        connection.close()

    def test_hadith_grade_is_attributed(self):
        connection = self.load("content_v1.sql")
        columns = {
            row[1] for row in connection.execute("PRAGMA table_info(grade_assertion)")
        }
        self.assertTrue(
            {"grade_text", "grader", "source", "source_version"}.issubset(columns)
        )
        connection.close()

    def test_exposure_history_is_append_only(self):
        connection = self.load("user_v1.sql")
        connection.execute(
            "INSERT INTO exposure_event VALUES (?,?,?,?,?,?)",
            (
                "xe:1",
                "lx:1",
                "quick_meaning_opened",
                "qa:001:001",
                "2026-09-20T00:00:00Z",
                "{}",
            ),
        )
        with self.assertRaises(sqlite3.DatabaseError):
            connection.execute(
                "UPDATE exposure_event SET event_type='explicitly_known' "
                "WHERE exposure_event_id='xe:1'"
            )
        with self.assertRaises(sqlite3.DatabaseError):
            connection.execute(
                "DELETE FROM exposure_event WHERE exposure_event_id='xe:1'"
            )
        connection.close()

    def test_passive_visibility_is_not_a_review_event(self):
        connection = self.load("user_v1.sql")
        connection.execute(
            "INSERT INTO exposure_event VALUES (?,?,?,?,?,?)",
            (
                "xe:2",
                "lx:2",
                "passive_visible",
                "qa:002:255",
                "2026-09-20T00:00:00Z",
                "{}",
            ),
        )
        count = connection.execute("SELECT COUNT(*) FROM review_event").fetchone()[0]
        self.assertEqual(0, count)
        connection.close()


if __name__ == "__main__":
    unittest.main()
