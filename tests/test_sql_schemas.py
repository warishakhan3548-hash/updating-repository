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

    def test_source_faithful_quran_rows_are_immutable(self):
        connection = self.load("content_v1.sql")
        digest = "0" * 64
        connection.execute(
            "INSERT INTO source_assertion VALUES (?,?,?,?,?,?)",
            ("sa:quran", "fixture", "1", digest, "quran-text", "{}"),
        )
        connection.execute(
            "INSERT INTO quran_ayah VALUES (?,?,?,?,?,?,?)",
            (
                "qa:001:001",
                1,
                1,
                "SYNTHETIC-NOT-QURAN",
                "synthetic",
                "synthetic",
                "sa:quran",
            ),
        )
        connection.execute(
            "INSERT INTO quran_token VALUES (?,?,?,?,?)",
            ("qt:001:001:001", "qa:001:001", 1, "SYNTHETIC", "synthetic"),
        )
        connection.execute(
            "INSERT INTO quran_segment VALUES (?,?,?,?,?,?)",
            ("qs:001:001:001:001", "qt:001:001:001", 1, "SYN", "{}", "sa:quran"),
        )
        for statement in (
            "UPDATE quran_ayah SET original_text='changed' WHERE ayah_id='qa:001:001'",
            "UPDATE quran_token SET original_text='changed' WHERE token_id='qt:001:001:001'",
            "UPDATE quran_segment SET original_text='changed' WHERE segment_id='qs:001:001:001:001'",
            "DELETE FROM source_assertion WHERE source_assertion_id='sa:quran'",
        ):
            with self.assertRaises(sqlite3.DatabaseError):
                connection.execute(statement)
        connection.close()

    def test_source_faithful_hadith_rows_and_grades_are_immutable(self):
        connection = self.load("content_v1.sql")
        digest = "0" * 64
        connection.execute(
            "INSERT INTO source_assertion VALUES (?,?,?,?,?,?)",
            ("sa:hadith", "fixture", "1", digest, "hadith-edition", "{}"),
        )
        connection.execute(
            "INSERT INTO hadith_edition VALUES (?,?,?,?,?,?)",
            ("ed:fixture", "fixture", "fixture edition", "1", "fixture numbering", "sa:hadith"),
        )
        connection.execute(
            "INSERT INTO hadith_record VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                "hr:fixture",
                "ed:fixture",
                "fixture-key",
                "book",
                "chapter",
                "1",
                "SYNTHETIC-NOT-HADITH",
                "synthetic-isnad",
                "synthetic-matn",
                "synthetic-exact",
                "synthetic-matn",
                "synthetic-isnad",
                "synthetic-orthographic",
            ),
        )
        connection.execute(
            "INSERT INTO citation VALUES (?,?,?)",
            ("ct:fixture", "hr:fixture", "fixture citation"),
        )
        connection.execute(
            "INSERT INTO grade_assertion VALUES (?,?,?,?,?,?)",
            ("ga:fixture", "hr:fixture", "fixture grade", "fixture grader", "fixture source", "1"),
        )
        for statement in (
            "UPDATE hadith_edition SET collection_name='changed' WHERE edition_id='ed:fixture'",
            "UPDATE hadith_record SET original_arabic='changed' WHERE hadith_record_id='hr:fixture'",
            "UPDATE citation SET display_citation='changed' WHERE citation_id='ct:fixture'",
            "UPDATE grade_assertion SET grade_text='changed' WHERE grade_assertion_id='ga:fixture'",
        ):
            with self.assertRaises(sqlite3.DatabaseError):
                connection.execute(statement)
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
