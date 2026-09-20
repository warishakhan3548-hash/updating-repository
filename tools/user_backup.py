#!/usr/bin/env python3
"""Versioned local export/restore contract for precious user learning history.

The backup is intentionally local, provider-agnostic and plaintext. It preserves
the user SQLite schema and durable rows exactly while dropping rebuildable
scheduler cache state. Integrity hashes detect accidental corruption; they are
not an authenticity or encryption mechanism.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile
import zipfile

FORMAT_ID = "aaris-user-backup"
FORMAT_VERSION = 1
CURRENT_USER_SCHEMA_VERSION = 2

MANIFEST_MEMBER = "manifest.json"
DATABASE_MEMBER = "user.sqlite"
MAX_MANIFEST_BYTES = 256 * 1024
MAX_DATABASE_BYTES = 2 * 1024 * 1024 * 1024

DURABLE_TABLES = (
    "exposure_event",
    "review_event",
    "bookmark",
    "note",
    "preference",
)
DERIVED_TABLES = ("memory_state_cache",)

EXPECTED_V2_COLUMNS = {
    "exposure_event": (
        "exposure_event_id",
        "semantic_unit_id",
        "event_type",
        "context_ref",
        "occurred_at_utc",
        "metadata_json",
        "event_schema_version",
    ),
    "review_event": (
        "review_event_id",
        "semantic_unit_id",
        "scheduler_adapter",
        "outcome",
        "occurred_at_utc",
        "elapsed_ms",
        "metadata_json",
        "canonical_grade",
        "scheduler_version",
        "context_ref",
        "event_schema_version",
    ),
    "memory_state_cache": (
        "semantic_unit_id",
        "scheduler_adapter",
        "scheduler_version",
        "state_json",
        "rebuilt_through_utc",
    ),
    "bookmark": (
        "bookmark_id",
        "content_ref",
        "created_at_utc",
    ),
    "note": (
        "note_id",
        "content_ref",
        "body",
        "created_at_utc",
        "updated_at_utc",
    ),
    "preference": (
        "key",
        "value_json",
    ),
}


class UserBackupError(RuntimeError):
    pass


def _read_only_uri(path: Path) -> str:
    return path.resolve().as_uri() + "?mode=ro"


def _open_read_only(path: Path) -> sqlite3.Connection:
    if not path.is_file():
        raise UserBackupError(f"user database does not exist: {path}")
    return sqlite3.connect(_read_only_uri(path), uri=True)


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_json_bytes(value: object) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        + b"\n"
    )


def _validate_utc_timestamp(value: object) -> str:
    if not isinstance(value, str) or not value:
        raise UserBackupError("exported_at_utc must be a non-empty string")
    candidate = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError as exc:
        raise UserBackupError("exported_at_utc is not ISO-8601") from exc
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise UserBackupError("exported_at_utc must include a timezone")
    if parsed.utcoffset().total_seconds() != 0:
        raise UserBackupError("exported_at_utc must be UTC")
    return value


def _default_exported_at_utc() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _table_columns(
    connection: sqlite3.Connection,
    table: str,
) -> tuple[str, ...]:
    return tuple(
        row[1]
        for row in connection.execute(
            f"PRAGMA table_info({table})"
        ).fetchall()
    )


def _record_counts(
    connection: sqlite3.Connection,
) -> dict[str, int]:
    return {
        table: int(
            connection.execute(
                f"SELECT COUNT(*) FROM {table}"
            ).fetchone()[0]
        )
        for table in DURABLE_TABLES
    }


def _validate_database_connection(
    connection: sqlite3.Connection,
    *,
    require_empty_derived: bool,
) -> dict[str, int]:
    version = int(connection.execute("PRAGMA user_version").fetchone()[0])
    if version != CURRENT_USER_SCHEMA_VERSION:
        raise UserBackupError(
            "unsupported user database schema version: "
            f"{version}; expected {CURRENT_USER_SCHEMA_VERSION}"
        )

    integrity = [
        row[0]
        for row in connection.execute("PRAGMA integrity_check").fetchall()
    ]
    if integrity != ["ok"]:
        raise UserBackupError(
            "user database failed SQLite integrity_check: "
            + "; ".join(str(item) for item in integrity[:5])
        )

    foreign_keys = connection.execute(
        "PRAGMA foreign_key_check"
    ).fetchall()
    if foreign_keys:
        raise UserBackupError(
            "user database contains foreign-key violations"
        )

    for table, expected in EXPECTED_V2_COLUMNS.items():
        actual = _table_columns(connection, table)
        if actual != expected:
            raise UserBackupError(
                f"{table} schema mismatch: "
                f"expected {expected!r}, got {actual!r}"
            )

    if require_empty_derived:
        for table in DERIVED_TABLES:
            count = int(
                connection.execute(
                    f"SELECT COUNT(*) FROM {table}"
                ).fetchone()[0]
            )
            if count != 0:
                raise UserBackupError(
                    f"derived table {table} must be empty in backup"
                )

    return _record_counts(connection)


def validate_user_database(path: Path) -> dict[str, int]:
    connection = _open_read_only(path)
    try:
        return _validate_database_connection(
            connection,
            require_empty_derived=False,
        )
    finally:
        connection.close()


def _copy_consistent_database(
    source_path: Path,
    destination_path: Path,
) -> None:
    source = _open_read_only(source_path)
    destination = sqlite3.connect(destination_path)
    try:
        source.backup(destination)
        destination.commit()

        for table in DERIVED_TABLES:
            destination.execute(f"DELETE FROM {table}")
        destination.commit()

        # Rebuild the file after dropping derived cache rows so stale cache bytes
        # are not intentionally carried inside free pages of the portable copy.
        destination.execute("VACUUM")
        destination.commit()

        _validate_database_connection(
            destination,
            require_empty_derived=True,
        )
    finally:
        destination.close()
        source.close()


def _manifest_for_database(
    database_path: Path,
    *,
    exported_at_utc: str,
) -> dict:
    connection = _open_read_only(database_path)
    try:
        counts = _validate_database_connection(
            connection,
            require_empty_derived=True,
        )
    finally:
        connection.close()

    return {
        "format_id": FORMAT_ID,
        "format_version": FORMAT_VERSION,
        "exported_at_utc": _validate_utc_timestamp(exported_at_utc),
        "source_user_schema_version": CURRENT_USER_SCHEMA_VERSION,
        "database_member": DATABASE_MEMBER,
        "database_sha256": _sha256_file(database_path),
        "database_byte_size": database_path.stat().st_size,
        "durable_tables": list(DURABLE_TABLES),
        "excluded_derived_tables": list(DERIVED_TABLES),
        "record_counts": counts,
        "security": {
            "encrypted": False,
            "authenticated": False,
            "integrity_hash": "sha256",
        },
    }


def export_backup(
    source_database: Path,
    output_archive: Path,
    *,
    exported_at_utc: str | None = None,
) -> dict:
    source_database = source_database.resolve()
    output_archive = output_archive.resolve()

    validate_user_database(source_database)

    if output_archive.exists():
        raise UserBackupError(
            f"refusing to overwrite existing backup: {output_archive}"
        )
    output_archive.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(
        prefix="aaris-user-backup-"
    ) as temporary:
        snapshot_path = Path(temporary) / DATABASE_MEMBER
        _copy_consistent_database(source_database, snapshot_path)

        manifest = _manifest_for_database(
            snapshot_path,
            exported_at_utc=(
                exported_at_utc or _default_exported_at_utc()
            ),
        )
        manifest_bytes = _canonical_json_bytes(manifest)

        try:
            with zipfile.ZipFile(
                output_archive,
                mode="x",
                compression=zipfile.ZIP_DEFLATED,
                compresslevel=9,
            ) as archive:
                archive.writestr(MANIFEST_MEMBER, manifest_bytes)
                archive.write(snapshot_path, DATABASE_MEMBER)
        except Exception:
            output_archive.unlink(missing_ok=True)
            raise

    return manifest


def _validate_manifest(value: object) -> dict:
    if not isinstance(value, dict):
        raise UserBackupError("backup manifest must be a JSON object")

    if value.get("format_id") != FORMAT_ID:
        raise UserBackupError("unrecognized user backup format")
    if value.get("format_version") != FORMAT_VERSION:
        raise UserBackupError(
            "unsupported user backup format version: "
            f"{value.get('format_version')!r}"
        )
    if (
        value.get("source_user_schema_version")
        != CURRENT_USER_SCHEMA_VERSION
    ):
        raise UserBackupError(
            "unsupported source user schema version in backup"
        )
    if value.get("database_member") != DATABASE_MEMBER:
        raise UserBackupError("backup database member name mismatch")

    _validate_utc_timestamp(value.get("exported_at_utc"))

    digest = value.get("database_sha256")
    if (
        not isinstance(digest, str)
        or len(digest) != 64
        or any(ch not in "0123456789abcdef" for ch in digest)
    ):
        raise UserBackupError("backup database SHA-256 is invalid")

    byte_size = value.get("database_byte_size")
    if (
        not isinstance(byte_size, int)
        or isinstance(byte_size, bool)
        or byte_size < 1
        or byte_size > MAX_DATABASE_BYTES
    ):
        raise UserBackupError("backup database byte size is invalid")

    if value.get("durable_tables") != list(DURABLE_TABLES):
        raise UserBackupError("backup durable-table contract mismatch")
    if value.get("excluded_derived_tables") != list(DERIVED_TABLES):
        raise UserBackupError(
            "backup derived-table exclusion contract mismatch"
        )

    counts = value.get("record_counts")
    if not isinstance(counts, dict) or set(counts) != set(DURABLE_TABLES):
        raise UserBackupError("backup record-count manifest is invalid")
    for table, count in counts.items():
        if (
            not isinstance(count, int)
            or isinstance(count, bool)
            or count < 0
        ):
            raise UserBackupError(
                f"backup record count is invalid for {table}"
            )

    security = value.get("security")
    if security != {
        "encrypted": False,
        "authenticated": False,
        "integrity_hash": "sha256",
    }:
        raise UserBackupError("backup security declaration mismatch")

    return value


def _load_archive_into_temp(
    archive_path: Path,
    temporary_root: Path,
) -> tuple[dict, Path]:
    if not archive_path.is_file():
        raise UserBackupError(
            f"user backup does not exist: {archive_path}"
        )

    try:
        archive = zipfile.ZipFile(archive_path, mode="r")
    except (OSError, zipfile.BadZipFile) as exc:
        raise UserBackupError("user backup is not a valid ZIP archive") from exc

    with archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        expected = [MANIFEST_MEMBER, DATABASE_MEMBER]
        if sorted(names) != sorted(expected) or len(names) != len(expected):
            raise UserBackupError(
                "backup must contain exactly manifest.json and user.sqlite"
            )
        if len(set(names)) != len(names):
            raise UserBackupError("backup contains duplicate members")

        by_name = {info.filename: info for info in infos}
        manifest_info = by_name[MANIFEST_MEMBER]
        database_info = by_name[DATABASE_MEMBER]

        if manifest_info.file_size > MAX_MANIFEST_BYTES:
            raise UserBackupError("backup manifest is too large")
        if (
            database_info.file_size < 1
            or database_info.file_size > MAX_DATABASE_BYTES
        ):
            raise UserBackupError("backup database member size is invalid")

        try:
            manifest_raw = archive.read(MANIFEST_MEMBER)
        except (OSError, RuntimeError, zipfile.BadZipFile) as exc:
            raise UserBackupError("cannot read backup manifest") from exc

        try:
            manifest_value = json.loads(
                manifest_raw.decode("utf-8")
            )
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise UserBackupError(
                "backup manifest is not valid UTF-8 JSON"
            ) from exc
        manifest = _validate_manifest(manifest_value)

        if manifest_raw != _canonical_json_bytes(manifest):
            raise UserBackupError(
                "backup manifest is not in canonical project JSON form"
            )
        if database_info.file_size != manifest["database_byte_size"]:
            raise UserBackupError(
                "backup database size does not match manifest"
            )

        database_path = temporary_root / DATABASE_MEMBER
        try:
            with archive.open(DATABASE_MEMBER, "r") as source:
                with database_path.open("xb") as destination:
                    shutil.copyfileobj(
                        source,
                        destination,
                        length=1024 * 1024,
                    )
        except (
            OSError,
            RuntimeError,
            zipfile.BadZipFile,
        ) as exc:
            raise UserBackupError(
                "cannot materialize backup database"
            ) from exc

    if database_path.stat().st_size != manifest["database_byte_size"]:
        raise UserBackupError(
            "materialized backup database size mismatch"
        )
    if _sha256_file(database_path) != manifest["database_sha256"]:
        raise UserBackupError(
            "backup database SHA-256 does not match manifest"
        )

    connection = _open_read_only(database_path)
    try:
        counts = _validate_database_connection(
            connection,
            require_empty_derived=True,
        )
    finally:
        connection.close()
    if counts != manifest["record_counts"]:
        raise UserBackupError(
            "backup record counts do not match manifest"
        )

    return manifest, database_path


def inspect_backup(archive_path: Path) -> dict:
    with tempfile.TemporaryDirectory(
        prefix="aaris-user-backup-inspect-"
    ) as temporary:
        manifest, _ = _load_archive_into_temp(
            archive_path.resolve(),
            Path(temporary),
        )
        return manifest


def _fsync_file(path: Path) -> None:
    with path.open("rb") as handle:
        os.fsync(handle.fileno())


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    try:
        descriptor = os.open(path, flags)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    except OSError:
        pass
    finally:
        os.close(descriptor)


def restore_backup(
    archive_path: Path,
    destination_database: Path,
) -> dict:
    archive_path = archive_path.resolve()
    destination_database = destination_database.resolve()

    if destination_database.exists():
        raise UserBackupError(
            "refusing to overwrite an existing user database"
        )
    destination_database.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(
        prefix="aaris-user-backup-restore-"
    ) as temporary:
        manifest, backup_database = _load_archive_into_temp(
            archive_path,
            Path(temporary),
        )

        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{destination_database.name}.",
            suffix=".restore.tmp",
            dir=destination_database.parent,
        )
        os.close(descriptor)
        temporary_destination = Path(temporary_name)
        try:
            shutil.copyfile(
                backup_database,
                temporary_destination,
            )
            _fsync_file(temporary_destination)

            connection = _open_read_only(temporary_destination)
            try:
                counts = _validate_database_connection(
                    connection,
                    require_empty_derived=True,
                )
            finally:
                connection.close()
            if counts != manifest["record_counts"]:
                raise UserBackupError(
                    "restored database record counts changed"
                )

            os.replace(
                temporary_destination,
                destination_database,
            )
            _fsync_directory(destination_database.parent)
        finally:
            temporary_destination.unlink(missing_ok=True)

    return manifest


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Export, inspect or restore a versioned local Aaris "
            "user-data backup."
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_parser = subparsers.add_parser("export")
    export_parser.add_argument("source_database", type=Path)
    export_parser.add_argument("output_archive", type=Path)

    inspect_parser = subparsers.add_parser("inspect")
    inspect_parser.add_argument("archive", type=Path)

    restore_parser = subparsers.add_parser("restore")
    restore_parser.add_argument("archive", type=Path)
    restore_parser.add_argument("destination_database", type=Path)

    return parser


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    try:
        if args.command == "export":
            manifest = export_backup(
                args.source_database,
                args.output_archive,
            )
        elif args.command == "inspect":
            manifest = inspect_backup(args.archive)
        elif args.command == "restore":
            manifest = restore_backup(
                args.archive,
                args.destination_database,
            )
        else:
            parser.error("unsupported command")
            return 2
    except UserBackupError as exc:
        parser.exit(1, f"user backup error: {exc}\n")
        return 1

    print(
        json.dumps(
            manifest,
            ensure_ascii=False,
            sort_keys=True,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
