import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import zipfile

from tools.user_backup import (
    DATABASE_MEMBER,
    MANIFEST_MEMBER,
    UserBackupError,
    export_backup,
    inspect_backup,
    restore_backup,
)

ROOT = Path(__file__).resolve().parents[1]


class UserBackupTests(unittest.TestCase):
    def _create_v2_database(self, path: Path) -> sqlite3.Connection:
        connection = sqlite3.connect(path)
        connection.executescript(
            (ROOT / "schemas" / "user_v2.sql").read_text(
                encoding="utf-8"
            )
        )
        return connection

    def _seed_v2_database(self, path: Path) -> None:
        connection = self._create_v2_database(path)
        try:
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
                    "quick_meaning_opened",
                    "qa:001:001",
                    "2026-09-21T00:00:00Z",
                ),
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
                    "re:1",
                    "lx:1",
                    "fsrs",
                    "good",
                    "2026-09-21T00:01:00Z",
                    "good",
                    "6",
                    "qa:001:001",
                ),
            )
            connection.execute(
                "INSERT INTO bookmark VALUES (?,?,?)",
                (
                    "bm:1",
                    "qa:002:255",
                    "2026-09-21T00:02:00Z",
                ),
            )
            connection.execute(
                "INSERT INTO note VALUES (?,?,?,?,?)",
                (
                    "note:1",
                    "qa:112:001",
                    "private learning note",
                    "2026-09-21T00:03:00Z",
                    "2026-09-21T00:03:00Z",
                ),
            )
            connection.execute(
                "INSERT INTO preference VALUES (?,?)",
                ("learning.language", '"ur"'),
            )
            connection.execute(
                "INSERT INTO memory_state_cache VALUES (?,?,?,?,?)",
                (
                    "lx:1",
                    "fsrs",
                    "6",
                    '{"stability":9.5}',
                    "2026-09-21T00:04:00Z",
                ),
            )
            connection.commit()
        finally:
            connection.close()

    def test_round_trip_preserves_durable_rows_and_drops_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.sqlite"
            backup = root / "history.aaris-backup"
            restored = root / "restored.sqlite"
            self._seed_v2_database(source)

            exported = export_backup(
                source,
                backup,
                exported_at_utc="2026-09-21T00:10:00Z",
            )
            inspected = inspect_backup(backup)
            restored_manifest = restore_backup(backup, restored)

            self.assertEqual(exported, inspected)
            self.assertEqual(exported, restored_manifest)
            self.assertEqual(
                {
                    "exposure_event": 1,
                    "review_event": 1,
                    "bookmark": 1,
                    "note": 1,
                    "preference": 1,
                },
                exported["record_counts"],
            )
            self.assertEqual(
                ["memory_state_cache"],
                exported["excluded_derived_tables"],
            )
            self.assertFalse(exported["security"]["encrypted"])
            self.assertFalse(exported["security"]["authenticated"])

            connection = sqlite3.connect(restored)
            try:
                self.assertEqual(
                    2,
                    connection.execute(
                        "PRAGMA user_version"
                    ).fetchone()[0],
                )
                self.assertEqual(
                    ("quick_meaning_opened", "qa:001:001"),
                    connection.execute(
                        """
                        SELECT event_type, context_ref
                        FROM exposure_event
                        WHERE exposure_event_id='xe:1'
                        """
                    ).fetchone(),
                )
                self.assertEqual(
                    ("good", "6", 2),
                    connection.execute(
                        """
                        SELECT canonical_grade,
                               scheduler_version,
                               event_schema_version
                        FROM review_event
                        WHERE review_event_id='re:1'
                        """
                    ).fetchone(),
                )
                self.assertEqual(
                    "private learning note",
                    connection.execute(
                        "SELECT body FROM note WHERE note_id='note:1'"
                    ).fetchone()[0],
                )
                self.assertEqual(
                    0,
                    connection.execute(
                        "SELECT COUNT(*) FROM memory_state_cache"
                    ).fetchone()[0],
                )
                self.assertEqual(
                    "ok",
                    connection.execute(
                        "PRAGMA integrity_check"
                    ).fetchone()[0],
                )
            finally:
                connection.close()

    def test_migrated_legacy_review_history_round_trips_without_reinterpretation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "migrated.sqlite"
            backup = root / "legacy-history.aaris-backup"
            restored = root / "restored.sqlite"

            connection = sqlite3.connect(source)
            try:
                connection.executescript(
                    (ROOT / "schemas" / "user_v1.sql").read_text(
                        encoding="utf-8"
                    )
                )
                connection.execute(
                    "INSERT INTO review_event VALUES (?,?,?,?,?,?,?)",
                    (
                        "re:legacy",
                        "lx:legacy",
                        "legacy-adapter",
                        "legacy_custom",
                        "2026-09-20T23:59:00Z",
                        None,
                        "{}",
                    ),
                )
                connection.executescript(
                    (
                        ROOT
                        / "schemas"
                        / "migrations"
                        / "user_v1_to_v2.sql"
                    ).read_text(encoding="utf-8")
                )
            finally:
                connection.close()

            export_backup(
                source,
                backup,
                exported_at_utc="2026-09-21T00:10:00Z",
            )
            restore_backup(backup, restored)

            connection = sqlite3.connect(restored)
            try:
                row = connection.execute(
                    """
                    SELECT outcome,
                           canonical_grade,
                           scheduler_version,
                           event_schema_version
                    FROM review_event
                    WHERE review_event_id='re:legacy'
                    """
                ).fetchone()
                self.assertEqual(
                    ("legacy_custom", None, None, 1),
                    row,
                )
            finally:
                connection.close()

    def test_tampered_database_member_fails_hash_before_restore(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.sqlite"
            backup = root / "history.aaris-backup"
            tampered = root / "tampered.aaris-backup"
            self._seed_v2_database(source)
            export_backup(
                source,
                backup,
                exported_at_utc="2026-09-21T00:10:00Z",
            )

            with zipfile.ZipFile(backup, "r") as original:
                manifest = original.read(MANIFEST_MEMBER)
                database = original.read(DATABASE_MEMBER)

            with zipfile.ZipFile(
                tampered,
                "w",
                compression=zipfile.ZIP_DEFLATED,
            ) as archive:
                archive.writestr(MANIFEST_MEMBER, manifest)
                archive.writestr(DATABASE_MEMBER, database + b"tamper")

            with self.assertRaisesRegex(
                UserBackupError,
                "size does not match manifest|SHA-256",
            ):
                inspect_backup(tampered)

    def test_noncanonical_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.sqlite"
            backup = root / "history.aaris-backup"
            rewritten = root / "rewritten.aaris-backup"
            self._seed_v2_database(source)
            export_backup(
                source,
                backup,
                exported_at_utc="2026-09-21T00:10:00Z",
            )

            with zipfile.ZipFile(backup, "r") as original:
                manifest = json.loads(
                    original.read(MANIFEST_MEMBER).decode("utf-8")
                )
                database = original.read(DATABASE_MEMBER)

            pretty_manifest = (
                json.dumps(manifest, ensure_ascii=False, indent=2)
                + "\n"
            ).encode("utf-8")
            with zipfile.ZipFile(rewritten, "w") as archive:
                archive.writestr(
                    MANIFEST_MEMBER,
                    pretty_manifest,
                )
                archive.writestr(DATABASE_MEMBER, database)

            with self.assertRaisesRegex(
                UserBackupError,
                "canonical project JSON",
            ):
                inspect_backup(rewritten)

    def test_extra_archive_member_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.sqlite"
            backup = root / "history.aaris-backup"
            rewritten = root / "extra.aaris-backup"
            self._seed_v2_database(source)
            export_backup(
                source,
                backup,
                exported_at_utc="2026-09-21T00:10:00Z",
            )

            with zipfile.ZipFile(backup, "r") as original:
                manifest = original.read(MANIFEST_MEMBER)
                database = original.read(DATABASE_MEMBER)

            with zipfile.ZipFile(rewritten, "w") as archive:
                archive.writestr(MANIFEST_MEMBER, manifest)
                archive.writestr(DATABASE_MEMBER, database)
                archive.writestr("../unexpected.txt", b"x")

            with self.assertRaisesRegex(
                UserBackupError,
                "exactly manifest.json and user.sqlite",
            ):
                inspect_backup(rewritten)

    def test_restore_refuses_to_overwrite_existing_database(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.sqlite"
            backup = root / "history.aaris-backup"
            destination = root / "existing.sqlite"
            self._seed_v2_database(source)
            export_backup(
                source,
                backup,
                exported_at_utc="2026-09-21T00:10:00Z",
            )
            destination.write_bytes(b"do-not-overwrite")

            with self.assertRaisesRegex(
                UserBackupError,
                "refusing to overwrite",
            ):
                restore_backup(backup, destination)
            self.assertEqual(
                b"do-not-overwrite",
                destination.read_bytes(),
            )

    def test_unknown_user_schema_version_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "future.sqlite"
            backup = root / "future.aaris-backup"
            self._seed_v2_database(source)

            connection = sqlite3.connect(source)
            try:
                connection.execute("PRAGMA user_version = 99")
                connection.commit()
            finally:
                connection.close()

            with self.assertRaisesRegex(
                UserBackupError,
                "unsupported user database schema version",
            ):
                export_backup(
                    source,
                    backup,
                    exported_at_utc="2026-09-21T00:10:00Z",
                )
            self.assertFalse(backup.exists())


if __name__ == "__main__":
    unittest.main()
