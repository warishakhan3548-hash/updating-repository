import hashlib
import json
import sqlite3
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from user_backup import (  # noqa: E402
    DATABASE_ENTRY,
    MANIFEST_ENTRY,
    UserBackupError,
    export_backup,
    inspect_backup,
    restore_backup,
)


class UserBackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def make_v2(self, name="user.sqlite"):
        path = self.root / name
        connection = sqlite3.connect(path)
        connection.executescript(
            (ROOT / "schemas" / "user_v2.sql").read_text(
                encoding="utf-8"
            )
        )
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
              elapsed_ms,
              canonical_grade,
              scheduler_version,
              context_ref
            ) VALUES (?,?,?,?,?,?,?,?,?)
            """,
            (
                "re:1",
                "lx:1",
                "fsrs",
                "good",
                "2026-09-21T00:01:00Z",
                350,
                "good",
                "6",
                "qa:001:001",
            ),
        )
        connection.execute(
            "INSERT INTO bookmark VALUES (?,?,?)",
            (
                "b:1",
                "qa:001:001",
                "2026-09-21T00:02:00Z",
            ),
        )
        connection.execute(
            "INSERT INTO note VALUES (?,?,?,?,?)",
            (
                "n:1",
                "qa:001:001",
                "remember",
                "2026-09-21T00:03:00Z",
                "2026-09-21T00:03:00Z",
            ),
        )
        connection.execute(
            "INSERT INTO preference VALUES (?,?)",
            (
                "reader.text_scale",
                "1.15",
            ),
        )
        connection.commit()
        connection.close()
        return path

    def test_round_trip_preserves_user_database_and_manifest_hash(self):
        source = self.make_v2()
        backup = self.root / "learning.aarisbackup"
        manifest = export_backup(
            source,
            backup,
            created_at_utc="2026-09-21T00:10:00Z",
        )

        self.assertEqual(
            "aaris-user-backup",
            manifest["backup_format"],
        )
        self.assertEqual(
            1,
            manifest["format_version"],
        )
        self.assertEqual(
            2,
            manifest["database"]["user_schema_version"],
        )
        self.assertEqual(
            manifest,
            inspect_backup(backup),
        )

        restored = self.root / "restored.sqlite"
        restore_backup(
            backup,
            restored,
        )
        self.assertEqual(
            manifest["database"]["sha256"],
            hashlib.sha256(
                restored.read_bytes()
            ).hexdigest(),
        )

        connection = sqlite3.connect(restored)
        self.assertEqual(
            2,
            connection.execute(
                "PRAGMA user_version"
            ).fetchone()[0],
        )
        self.assertEqual(
            (
                "good",
                "6",
                "qa:001:001",
            ),
            connection.execute(
                """
                SELECT
                  canonical_grade,
                  scheduler_version,
                  context_ref
                FROM review_event
                WHERE review_event_id='re:1'
                """
            ).fetchone(),
        )
        self.assertEqual(
            ("remember",),
            connection.execute(
                """
                SELECT body
                FROM note
                WHERE note_id='n:1'
                """
            ).fetchone(),
        )
        connection.close()

    def test_archive_with_extra_file_fails_closed(self):
        source = self.make_v2()
        valid = self.root / "valid.aarisbackup"
        export_backup(
            source,
            valid,
            created_at_utc="2026-09-21T00:10:00Z",
        )
        bad = self.root / "extra.aarisbackup"

        with (
            zipfile.ZipFile(valid, "r") as original,
            zipfile.ZipFile(bad, "w") as output,
        ):
            for info in original.infolist():
                output.writestr(
                    info,
                    original.read(info.filename),
                )
            output.writestr(
                "surprise.txt",
                "unexpected",
            )

        with self.assertRaisesRegex(
            UserBackupError,
            "exactly",
        ):
            inspect_backup(bad)

    def test_hash_mismatch_fails_closed(self):
        source = self.make_v2()
        valid = self.root / "valid.aarisbackup"
        export_backup(
            source,
            valid,
            created_at_utc="2026-09-21T00:10:00Z",
        )
        bad = self.root / "tampered.aarisbackup"

        with zipfile.ZipFile(
            valid,
            "r",
        ) as original:
            manifest = json.loads(
                original.read(MANIFEST_ENTRY)
            )
            database = bytearray(
                original.read(DATABASE_ENTRY)
            )

        database[-1] ^= 1
        with zipfile.ZipFile(
            bad,
            "w",
        ) as output:
            output.writestr(
                MANIFEST_ENTRY,
                json.dumps(manifest),
            )
            output.writestr(
                DATABASE_ENTRY,
                database,
            )

        with self.assertRaisesRegex(
            UserBackupError,
            "SHA-256 mismatch",
        ):
            inspect_backup(bad)

    def test_unsupported_user_schema_version_fails_export(self):
        source = self.make_v2()
        connection = sqlite3.connect(source)
        connection.execute(
            "PRAGMA user_version = 99"
        )
        connection.commit()
        connection.close()

        with self.assertRaisesRegex(
            UserBackupError,
            "unsupported user schema version",
        ):
            export_backup(
                source,
                self.root / "bad.aarisbackup",
            )

    def test_restore_refuses_to_overwrite_existing_database(self):
        source = self.make_v2()
        backup = self.root / "valid.aarisbackup"
        export_backup(
            source,
            backup,
            created_at_utc="2026-09-21T00:10:00Z",
        )
        destination = self.root / "existing.sqlite"
        destination.write_bytes(
            b"existing"
        )

        with self.assertRaisesRegex(
            UserBackupError,
            "refusing to overwrite",
        ):
            restore_backup(
                backup,
                destination,
            )

    def test_manifest_user_version_must_match_database(self):
        source = self.make_v2()
        valid = self.root / "valid.aarisbackup"
        export_backup(
            source,
            valid,
            created_at_utc="2026-09-21T00:10:00Z",
        )
        bad = self.root / "version-mismatch.aarisbackup"

        with zipfile.ZipFile(
            valid,
            "r",
        ) as original:
            manifest = json.loads(
                original.read(MANIFEST_ENTRY)
            )
            database = original.read(
                DATABASE_ENTRY
            )

        manifest["database"][
            "user_schema_version"
        ] = 1

        with zipfile.ZipFile(
            bad,
            "w",
        ) as output:
            output.writestr(
                MANIFEST_ENTRY,
                json.dumps(manifest),
            )
            output.writestr(
                DATABASE_ENTRY,
                database,
            )

        with self.assertRaisesRegex(
            UserBackupError,
            "user_version does not match",
        ):
            inspect_backup(bad)


if __name__ == "__main__":
    unittest.main()
