import sqlite3
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class UserSchemaMigrationTests(unittest.TestCase):
    def fresh_connection(self) -> sqlite3.Connection:
        return sqlite3.connect(":memory:")

    def load_schema(self, connection: sqlite3.Connection, name: str) -> None:
        connection.executescript(
            (ROOT / "schemas" / name).read_text(encoding="utf-8")
        )

    def migrate_v1_to_v2(self, connection: sqlite3.Connection) -> None:
        connection.executescript(
            (
                ROOT
                / "schemas"
                / "migrations"
                / "user_v1_to_v2.sql"
            ).read_text(encoding="utf-8")
        )

    def test_fresh_v2_requires_canonical_review_grade_and_scheduler_version(self):
        connection = self.fresh_connection()
        self.load_schema(connection, "user_v2.sql")

        self.assertEqual(2, connection.execute("PRAGMA user_version").fetchone()[0])

        connection.execute(
            """
            INSERT INTO review_event (
              review_event_id,
              semantic_unit_id,
              scheduler_adapter,
              outcome,
              occurred_at_utc,
              canonical_grade,
              scheduler_version,
              context_ref
            ) VALUES (?,?,?,?,?,?,?,?)
            """,
            (
                "re:1",
                "lx:1",
                "fsrs",
                "good",
                "2026-09-20T00:00:00Z",
                "good",
                "6",
                "qa:001:001",
            ),
        )

        row = connection.execute(
            """
            SELECT canonical_grade, scheduler_version, context_ref, event_schema_version
            FROM review_event
            WHERE review_event_id='re:1'
            """
        ).fetchone()
        self.assertEqual(("good", "6", "qa:001:001", 2), row)

        with self.assertRaises(sqlite3.DatabaseError):
            connection.execute(
                """
                INSERT INTO review_event (
                  review_event_id,
                  semantic_unit_id,
                  scheduler_adapter,
                  outcome,
                  occurred_at_utc,
                  scheduler_version
                ) VALUES (?,?,?,?,?,?)
                """,
                (
                    "re:missing-grade",
                    "lx:2",
                    "fsrs",
                    "good",
                    "2026-09-20T00:01:00Z",
                    "6",
                ),
            )

        with self.assertRaises(sqlite3.DatabaseError):
            connection.execute(
                """
                INSERT INTO review_event (
                  review_event_id,
                  semantic_unit_id,
                  scheduler_adapter,
                  outcome,
                  occurred_at_utc,
                  canonical_grade,
                  scheduler_version
                ) VALUES (?,?,?,?,?,?,?)
                """,
                (
                    "re:mismatch",
                    "lx:3",
                    "fsrs",
                    "hard",
                    "2026-09-20T00:02:00Z",
                    "good",
                    "6",
                ),
            )

        connection.close()

    def test_fresh_v2_new_exposures_are_schema_v2_and_not_reviews(self):
        connection = self.fresh_connection()
        self.load_schema(connection, "user_v2.sql")

        connection.execute(
            """
            INSERT INTO exposure_event (
              exposure_event_id,
              semantic_unit_id,
              event_type,
              context_ref,
              occurred_at_utc
            ) VALUES (?,?,?,?,?)
            """,
            (
                "xe:1",
                "lx:1",
                "passive_visible",
                "qa:002:255",
                "2026-09-20T00:00:00Z",
            ),
        )

        self.assertEqual(
            2,
            connection.execute(
                "SELECT event_schema_version FROM exposure_event WHERE exposure_event_id='xe:1'"
            ).fetchone()[0],
        )
        self.assertEqual(
            0,
            connection.execute("SELECT COUNT(*) FROM review_event").fetchone()[0],
        )

        with self.assertRaises(sqlite3.DatabaseError):
            connection.execute(
                """
                INSERT INTO exposure_event (
                  exposure_event_id,
                  semantic_unit_id,
                  event_type,
                  occurred_at_utc,
                  event_schema_version
                ) VALUES (?,?,?,?,?)
                """,
                (
                    "xe:legacy",
                    "lx:2",
                    "explicitly_unknown",
                    "2026-09-20T00:01:00Z",
                    1,
                ),
            )

        connection.close()

    def test_v1_to_v2_preserves_history_without_guessing_unknown_outcomes(self):
        connection = self.fresh_connection()
        self.load_schema(connection, "user_v1.sql")

        connection.execute(
            "INSERT INTO exposure_event VALUES (?,?,?,?,?,?)",
            (
                "xe:legacy",
                "lx:1",
                "quick_meaning_opened",
                "qa:001:001",
                "2026-09-19T23:58:00Z",
                "{}",
            ),
        )
        connection.execute(
            "INSERT INTO review_event VALUES (?,?,?,?,?,?,?)",
            (
                "re:known",
                "lx:1",
                "legacy-adapter",
                "good",
                "2026-09-19T23:59:00Z",
                450,
                "{}",
            ),
        )
        connection.execute(
            "INSERT INTO review_event VALUES (?,?,?,?,?,?,?)",
            (
                "re:unknown",
                "lx:2",
                "legacy-adapter",
                "legacy_custom",
                "2026-09-20T00:00:00Z",
                None,
                "{}",
            ),
        )

        self.migrate_v1_to_v2(connection)

        self.assertEqual(2, connection.execute("PRAGMA user_version").fetchone()[0])
        self.assertEqual(
            1,
            connection.execute("SELECT COUNT(*) FROM exposure_event").fetchone()[0],
        )
        self.assertEqual(
            2,
            connection.execute("SELECT COUNT(*) FROM review_event").fetchone()[0],
        )

        known = connection.execute(
            """
            SELECT canonical_grade, scheduler_version, context_ref, event_schema_version
            FROM review_event
            WHERE review_event_id='re:known'
            """
        ).fetchone()
        self.assertEqual(("good", None, None, 1), known)

        unknown = connection.execute(
            """
            SELECT outcome, canonical_grade, event_schema_version
            FROM review_event
            WHERE review_event_id='re:unknown'
            """
        ).fetchone()
        self.assertEqual(("legacy_custom", None, 1), unknown)

        with self.assertRaises(sqlite3.DatabaseError):
            connection.execute(
                "UPDATE review_event SET outcome='easy' WHERE review_event_id='re:known'"
            )

        connection.execute(
            """
            INSERT INTO review_event (
              review_event_id,
              semantic_unit_id,
              scheduler_adapter,
              outcome,
              occurred_at_utc,
              canonical_grade,
              scheduler_version,
              context_ref
            ) VALUES (?,?,?,?,?,?,?,?)
            """,
            (
                "re:new",
                "lx:1",
                "fsrs",
                "hard",
                "2026-09-20T00:05:00Z",
                "hard",
                "6",
                "qa:001:001",
            ),
        )
        self.assertEqual(
            2,
            connection.execute(
                "SELECT event_schema_version FROM review_event WHERE review_event_id='re:new'"
            ).fetchone()[0],
        )

        connection.close()


if __name__ == "__main__":
    unittest.main()
