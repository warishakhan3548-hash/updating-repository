#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import stat
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import BinaryIO

BACKUP_FORMAT = "aaris-user-backup"
FORMAT_VERSION = 1
MANIFEST_ENTRY = "manifest.json"
DATABASE_ENTRY = "user.sqlite"
SUPPORTED_USER_SCHEMA_VERSIONS = {2}
SCHEMA_ROOT = Path(__file__).resolve().parents[1] / "schemas"
USER_SCHEMA_FILES = {
    2: SCHEMA_ROOT / "user_v2.sql",
}
MAX_MANIFEST_BYTES = 64 * 1024
MAX_DATABASE_BYTES = 1024 * 1024 * 1024


class UserBackupError(RuntimeError):
    pass


def _sha256_stream(
    handle: BinaryIO,
    destination: BinaryIO | None = None,
) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        total += len(chunk)
        if total > MAX_DATABASE_BYTES:
            raise UserBackupError(
                "user.sqlite exceeds the supported backup size limit"
            )
        digest.update(chunk)
        if destination is not None:
            destination.write(chunk)
    return digest.hexdigest(), total


def sha256_file(path: Path) -> str:
    with path.open("rb") as handle:
        return _sha256_stream(handle)[0]


def _parse_created_at(value: object) -> str:
    if not isinstance(value, str) or not value:
        raise UserBackupError("manifest created_at_utc is missing")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise UserBackupError(
            "manifest created_at_utc is not ISO-8601"
        ) from exc
    if parsed.tzinfo is None:
        raise UserBackupError(
            "manifest created_at_utc must include a timezone"
        )
    return value


def _connect_read_only(path: Path) -> sqlite3.Connection:
    try:
        return sqlite3.connect(
            f"{path.resolve().as_uri()}?mode=ro",
            uri=True,
        )
    except sqlite3.Error as exc:
        raise UserBackupError(
            f"cannot open SQLite database read-only: {exc}"
        ) from exc


def _normalize_schema_sql(value: str | None) -> str:
    if value is None:
        return ""
    return " ".join(value.split())


def _schema_contract(
    connection: sqlite3.Connection,
) -> tuple[tuple[str, str, str, str], ...]:
    rows = connection.execute(
        """
        SELECT type, name, tbl_name, sql
        FROM sqlite_schema
        ORDER BY type, name
        """
    ).fetchall()
    return tuple(
        (
            str(object_type),
            str(name),
            str(table_name),
            _normalize_schema_sql(sql),
        )
        for object_type, name, table_name, sql in rows
    )


def _expected_schema_contract(
    user_version: int,
) -> tuple[tuple[str, str, str, str], ...]:
    schema_path = USER_SCHEMA_FILES.get(user_version)
    if schema_path is None or not schema_path.is_file():
        raise UserBackupError(
            "canonical user schema definition is unavailable "
            f"for version {user_version}"
        )

    expected = sqlite3.connect(":memory:")
    try:
        expected.executescript(
            schema_path.read_text(encoding="utf-8")
        )
        expected_version = int(
            expected.execute(
                "PRAGMA user_version"
            ).fetchone()[0]
        )
        if expected_version != user_version:
            raise UserBackupError(
                "canonical user schema version does not match "
                f"expected version {user_version}"
            )
        return _schema_contract(expected)
    except sqlite3.Error as exc:
        raise UserBackupError(
            f"cannot load canonical user schema: {exc}"
        ) from exc
    finally:
        expected.close()


def _validate_user_database(path: Path) -> int:
    if not path.is_file():
        raise UserBackupError(
            f"user database does not exist: {path}"
        )
    if path.stat().st_size < 1:
        raise UserBackupError("user database is empty")
    if path.stat().st_size > MAX_DATABASE_BYTES:
        raise UserBackupError(
            "user database exceeds the supported backup size limit"
        )

    connection = _connect_read_only(path)
    try:
        try:
            # SQLite recommends reducing trust in schema-controlled behavior
            # before inspecting a database that may have come from elsewhere.
            connection.execute("PRAGMA trusted_schema = OFF")
            connection.execute("PRAGMA mmap_size = 0")
            connection.execute("PRAGMA cell_size_check = ON")
            connection.execute("PRAGMA query_only = ON")

            integrity_check = connection.execute(
                "PRAGMA integrity_check"
            ).fetchall()
            if integrity_check != [("ok",)]:
                raise UserBackupError(
                    "SQLite integrity_check failed"
                )

            user_version = int(
                connection.execute(
                    "PRAGMA user_version"
                ).fetchone()[0]
            )
            if user_version not in SUPPORTED_USER_SCHEMA_VERSIONS:
                raise UserBackupError(
                    f"unsupported user schema version: {user_version}"
                )

            actual_schema = _schema_contract(connection)
            expected_schema = _expected_schema_contract(
                user_version
            )
            if actual_schema != expected_schema:
                raise UserBackupError(
                    "user database persistent schema does not "
                    "match the canonical schema contract"
                )
        except sqlite3.Error as exc:
            raise UserBackupError(
                f"invalid SQLite user database: {exc}"
            ) from exc
    finally:
        connection.close()

    return user_version


def _snapshot_database(
    source: Path,
    destination: Path,
) -> int:
    source_connection = _connect_read_only(source)
    destination_connection = sqlite3.connect(destination)
    try:
        try:
            source_connection.backup(destination_connection)
        except sqlite3.Error as exc:
            raise UserBackupError(
                f"SQLite backup failed: {exc}"
            ) from exc
    finally:
        destination_connection.close()
        source_connection.close()

    return _validate_user_database(destination)


def _manifest(
    *,
    created_at_utc: str,
    database_sha256: str,
    byte_size: int,
    user_schema_version: int,
) -> dict:
    return {
        "backup_format": BACKUP_FORMAT,
        "format_version": FORMAT_VERSION,
        "created_at_utc": created_at_utc,
        "database": {
            "entry": DATABASE_ENTRY,
            "sha256": database_sha256,
            "byte_size": byte_size,
            "user_schema_version": user_schema_version,
        },
    }


def _validate_manifest(
    manifest: object,
    database_info: zipfile.ZipInfo,
) -> dict:
    if not isinstance(manifest, dict):
        raise UserBackupError(
            "backup manifest must be a JSON object"
        )

    expected_top = {
        "backup_format",
        "format_version",
        "created_at_utc",
        "database",
    }
    if set(manifest) != expected_top:
        raise UserBackupError(
            "backup manifest has an unsupported shape"
        )
    if manifest.get("backup_format") != BACKUP_FORMAT:
        raise UserBackupError("unsupported backup format")
    if manifest.get("format_version") != FORMAT_VERSION:
        raise UserBackupError(
            "unsupported backup format version"
        )
    _parse_created_at(manifest.get("created_at_utc"))

    database = manifest.get("database")
    expected_database = {
        "entry",
        "sha256",
        "byte_size",
        "user_schema_version",
    }
    if (
        not isinstance(database, dict)
        or set(database) != expected_database
    ):
        raise UserBackupError(
            "backup database manifest has an unsupported shape"
        )
    if database.get("entry") != DATABASE_ENTRY:
        raise UserBackupError(
            "backup database entry name is invalid"
        )

    expected_hash = database.get("sha256")
    if (
        not isinstance(expected_hash, str)
        or len(expected_hash) != 64
        or any(
            ch not in "0123456789abcdef"
            for ch in expected_hash
        )
    ):
        raise UserBackupError(
            "backup database SHA-256 is invalid"
        )

    byte_size = database.get("byte_size")
    if (
        not isinstance(byte_size, int)
        or isinstance(byte_size, bool)
        or byte_size < 1
        or byte_size > MAX_DATABASE_BYTES
    ):
        raise UserBackupError(
            "backup database byte_size is invalid"
        )
    if database_info.file_size != byte_size:
        raise UserBackupError(
            "backup database byte_size does not match archive entry"
        )

    user_schema_version = database.get(
        "user_schema_version"
    )
    if (
        not isinstance(user_schema_version, int)
        or isinstance(user_schema_version, bool)
        or user_schema_version
        not in SUPPORTED_USER_SCHEMA_VERSIONS
    ):
        raise UserBackupError(
            "backup user schema version is unsupported"
        )

    return manifest


def _reject_unsafe_zip_entries(
    archive: zipfile.ZipFile,
) -> tuple[zipfile.ZipInfo, zipfile.ZipInfo]:
    infos = archive.infolist()
    if len(infos) != 2:
        raise UserBackupError(
            "backup archive must contain exactly "
            "manifest.json and user.sqlite"
        )

    by_name: dict[str, zipfile.ZipInfo] = {}
    for info in infos:
        if info.filename in by_name:
            raise UserBackupError(
                "backup archive contains duplicate entries"
            )
        if info.filename not in {
            MANIFEST_ENTRY,
            DATABASE_ENTRY,
        }:
            raise UserBackupError(
                "unexpected backup archive entry: "
                + info.filename
            )

        mode = (
            info.external_attr >> 16
        ) & 0o170000
        if stat.S_ISLNK(mode):
            raise UserBackupError(
                "backup archive entry must not be a symlink: "
                + info.filename
            )
        if info.is_dir():
            raise UserBackupError(
                "backup archive entry must be a file: "
                + info.filename
            )
        by_name[info.filename] = info

    return (
        by_name[MANIFEST_ENTRY],
        by_name[DATABASE_ENTRY],
    )


def _read_and_validate_archive(
    backup_path: Path,
    temp_directory: Path,
) -> tuple[dict, Path]:
    if not backup_path.is_file():
        raise UserBackupError(
            f"backup archive does not exist: {backup_path}"
        )

    try:
        archive = zipfile.ZipFile(backup_path, "r")
    except (OSError, zipfile.BadZipFile) as exc:
        raise UserBackupError(
            f"backup archive is not a valid ZIP file: {exc}"
        ) from exc

    with archive:
        manifest_info, database_info = (
            _reject_unsafe_zip_entries(archive)
        )
        if manifest_info.file_size > MAX_MANIFEST_BYTES:
            raise UserBackupError(
                "backup manifest is too large"
            )

        try:
            manifest_bytes = archive.read(
                MANIFEST_ENTRY
            )
        except (
            OSError,
            zipfile.BadZipFile,
            RuntimeError,
        ) as exc:
            raise UserBackupError(
                f"cannot read backup manifest: {exc}"
            ) from exc

        try:
            manifest = json.loads(
                manifest_bytes.decode("utf-8")
            )
        except (
            UnicodeDecodeError,
            json.JSONDecodeError,
        ) as exc:
            raise UserBackupError(
                "backup manifest is not valid UTF-8 JSON"
            ) from exc

        manifest = _validate_manifest(
            manifest,
            database_info,
        )
        extracted = temp_directory / DATABASE_ENTRY
        digest = hashlib.sha256()
        total = 0

        try:
            with (
                archive.open(
                    database_info,
                    "r",
                ) as source,
                extracted.open("xb") as destination,
            ):
                for chunk in iter(
                    lambda: source.read(
                        1024 * 1024
                    ),
                    b"",
                ):
                    total += len(chunk)
                    if total > MAX_DATABASE_BYTES:
                        raise UserBackupError(
                            "user.sqlite exceeds the "
                            "supported backup size limit"
                        )
                    digest.update(chunk)
                    destination.write(chunk)
        except (
            OSError,
            zipfile.BadZipFile,
            RuntimeError,
        ) as exc:
            raise UserBackupError(
                f"cannot extract backup database: {exc}"
            ) from exc

    database_manifest = manifest["database"]
    if total != database_manifest["byte_size"]:
        raise UserBackupError(
            "extracted database byte_size mismatch"
        )
    if (
        digest.hexdigest()
        != database_manifest["sha256"]
    ):
        raise UserBackupError(
            "extracted database SHA-256 mismatch"
        )

    actual_schema_version = (
        _validate_user_database(extracted)
    )
    if (
        actual_schema_version
        != database_manifest["user_schema_version"]
    ):
        raise UserBackupError(
            "database user_version does not match "
            "backup manifest"
        )

    return manifest, extracted


def export_backup(
    source_database: Path,
    output_backup: Path,
    *,
    created_at_utc: str | None = None,
) -> dict:
    source_database = source_database.resolve()
    output_backup = output_backup.resolve()

    if output_backup.exists():
        raise UserBackupError(
            "refusing to overwrite existing backup: "
            + str(output_backup)
        )
    if not output_backup.parent.is_dir():
        raise UserBackupError(
            "backup destination directory does not exist: "
            + str(output_backup.parent)
        )

    _validate_user_database(source_database)

    with tempfile.TemporaryDirectory(
        prefix=".aaris-user-backup-",
        dir=output_backup.parent,
    ) as temp:
        temp_directory = Path(temp)
        snapshot = temp_directory / DATABASE_ENTRY
        user_schema_version = _snapshot_database(
            source_database,
            snapshot,
        )
        database_sha256 = sha256_file(snapshot)
        byte_size = snapshot.stat().st_size
        created = (
            created_at_utc
            or datetime.now(timezone.utc)
            .isoformat()
            .replace("+00:00", "Z")
        )
        _parse_created_at(created)
        manifest = _manifest(
            created_at_utc=created,
            database_sha256=database_sha256,
            byte_size=byte_size,
            user_schema_version=user_schema_version,
        )

        archive_path = (
            temp_directory / "backup.zip"
        )
        with zipfile.ZipFile(
            archive_path,
            "x",
            compression=zipfile.ZIP_DEFLATED,
        ) as archive:
            archive.writestr(
                MANIFEST_ENTRY,
                json.dumps(
                    manifest,
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
            )
            archive.write(
                snapshot,
                DATABASE_ENTRY,
            )

        # Validate the exact archive bytes before
        # publishing the backup to its final path.
        with tempfile.TemporaryDirectory(
            prefix=".aaris-user-backup-verify-",
            dir=output_backup.parent,
        ) as verify_temp:
            _read_and_validate_archive(
                archive_path,
                Path(verify_temp),
            )

        os.replace(
            archive_path,
            output_backup,
        )

    return manifest


def inspect_backup(
    backup_path: Path,
) -> dict:
    backup_path = backup_path.resolve()
    with tempfile.TemporaryDirectory(
        prefix=".aaris-user-backup-inspect-"
    ) as temp:
        manifest, _ = _read_and_validate_archive(
            backup_path,
            Path(temp),
        )
        return manifest


def restore_backup(
    backup_path: Path,
    destination_database: Path,
) -> dict:
    backup_path = backup_path.resolve()
    destination_database = (
        destination_database.resolve()
    )

    if destination_database.exists():
        raise UserBackupError(
            "refusing to overwrite existing database: "
            + str(destination_database)
        )
    if not destination_database.parent.is_dir():
        raise UserBackupError(
            "restore destination directory does not exist: "
            + str(destination_database.parent)
        )

    sidecars = [
        destination_database.with_name(
            destination_database.name + "-wal"
        ),
        destination_database.with_name(
            destination_database.name + "-shm"
        ),
        destination_database.with_name(
            destination_database.name + "-journal"
        ),
    ]
    if any(path.exists() for path in sidecars):
        raise UserBackupError(
            "refusing restore while destination "
            "SQLite sidecar files exist"
        )

    with tempfile.TemporaryDirectory(
        prefix=".aaris-user-backup-restore-",
        dir=destination_database.parent,
    ) as temp:
        temp_directory = Path(temp)
        manifest, extracted = (
            _read_and_validate_archive(
                backup_path,
                temp_directory,
            )
        )
        publish_path = (
            temp_directory
            / "validated-user.sqlite"
        )
        shutil.copyfile(
            extracted,
            publish_path,
        )
        if (
            sha256_file(publish_path)
            != manifest["database"]["sha256"]
        ):
            raise UserBackupError(
                "restored database SHA-256 changed "
                "before publication"
            )
        _validate_user_database(
            publish_path
        )
        os.replace(
            publish_path,
            destination_database,
        )

    return manifest


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Create, inspect or restore a local "
            "Aaris user.sqlite backup."
        )
    )
    subparsers = parser.add_subparsers(
        dest="command",
        required=True,
    )

    export = subparsers.add_parser(
        "export",
        help="Create a validated backup archive.",
    )
    export.add_argument(
        "source_database",
        type=Path,
    )
    export.add_argument(
        "output_backup",
        type=Path,
    )

    inspect = subparsers.add_parser(
        "inspect",
        help="Validate and describe a backup.",
    )
    inspect.add_argument(
        "backup",
        type=Path,
    )

    restore = subparsers.add_parser(
        "restore",
        help=(
            "Restore a validated backup into "
            "a new destination path."
        ),
    )
    restore.add_argument(
        "backup",
        type=Path,
    )
    restore.add_argument(
        "destination_database",
        type=Path,
    )

    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.command == "export":
            manifest = export_backup(
                args.source_database,
                args.output_backup,
            )
        elif args.command == "inspect":
            manifest = inspect_backup(
                args.backup
            )
        else:
            manifest = restore_backup(
                args.backup,
                args.destination_database,
            )
    except UserBackupError as exc:
        print(
            f"error: {exc}",
            file=sys.stderr,
        )
        return 1

    print(
        json.dumps(
            manifest,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
