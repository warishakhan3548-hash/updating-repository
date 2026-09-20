#!/usr/bin/env python3
"""Independent semantic verifier for the immutable quran-core runtime pack.

A manifest SHA-256 identifies exact shipped bytes. This verifier establishes a
separate property: the runtime SQLite pack still faithfully represents the
production-approved Source Vault snapshot and the reviewed canonical schema.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sqlite3
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.quran_core import (
    SEARCH_NORMALIZATION_VERSION,
    SOURCE_ID,
    extract_tanzil_notice,
    load_production_source,
    normalize_search_diacritic_free,
    normalize_search_unicode,
)

PACK_ID = "quran-core"
SOURCE_ASSERTION_ID = "sa:quran.tanzil.uthmani.v1.1"
SUPPORTED_RELEASES = {
    "1.0.2": {
        "importer_version": "quran-core-importer-3",
        "record_count": 6236,
    }
}


class QuranPackSemanticError(RuntimeError):
    pass


def _release_expectations(manifest: dict[str, Any]) -> dict[str, Any]:
    version = manifest.get("content_version")
    release = SUPPORTED_RELEASES.get(version)
    if release is None:
        raise QuranPackSemanticError(
            "unsupported quran-core content_version for semantic verification: "
            f"{version!r}"
        )
    return release


def _safe_pack_file(root: Path, raw: object, field: str) -> Path:
    if not isinstance(raw, str) or not raw:
        raise QuranPackSemanticError(f"missing {field}")
    rel = Path(raw)
    if (
        rel.is_absolute()
        or ".." in rel.parts
        or not rel.parts
        or rel.parts[0] != "content-packs"
    ):
        raise QuranPackSemanticError(f"{field} must stay under content-packs/")
    path = root / rel
    if not path.is_file():
        raise QuranPackSemanticError(f"missing {field}: {rel}")
    try:
        path.resolve().relative_to((root / "content-packs").resolve())
    except ValueError as exc:
        raise QuranPackSemanticError(
            f"{field} resolves outside content-packs/"
        ) from exc
    return path.resolve()


def _source_evidence(root: Path) -> tuple[dict, list, dict[str, str]]:
    source, artifact, rows = load_production_source(root)
    notice = extract_tanzil_notice(artifact)
    notice_sha256 = hashlib.sha256(notice.encode("utf-8")).hexdigest()

    provenance_path = root / source["provenance"]
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    attribution = provenance.get("attribution")
    source_url = provenance.get("original_url")
    if not isinstance(attribution, str) or not attribution:
        raise QuranPackSemanticError("source provenance is missing attribution")
    if source_url != source.get("original_url"):
        raise QuranPackSemanticError(
            "source provenance URL does not match Source Vault registry"
        )

    derived = {
        "notice": notice,
        "notice_sha256": notice_sha256,
        "attribution": attribution,
        "source_url": source_url,
    }
    return source, rows, derived


def _verify_manifest_contract(
    root: Path,
    manifest: dict[str, Any],
    source: dict[str, Any],
    derived: dict[str, str],
    release: dict[str, Any],
) -> tuple[Path, Path]:
    if manifest.get("pack_id") != PACK_ID:
        raise QuranPackSemanticError(
            f"semantic verifier only supports pack_id={PACK_ID!r}"
        )
    if manifest.get("source_id") != SOURCE_ID:
        raise QuranPackSemanticError("quran-core source_id mismatch")
    if manifest.get("record_count") != release["record_count"]:
        raise QuranPackSemanticError(
            "quran-core manifest record_count does not match reviewed release"
        )
    if manifest.get("importer_version") != release["importer_version"]:
        raise QuranPackSemanticError(
            "quran-core importer_version does not match reviewed release"
        )
    if manifest.get("dependencies") != []:
        raise QuranPackSemanticError(
            "quran-core must not claim undeclared pack dependencies"
        )
    if manifest.get("search_normalization_version") != SEARCH_NORMALIZATION_VERSION:
        raise QuranPackSemanticError(
            "quran-core search normalization version mismatch"
        )

    expected_source_fields = {
        "source_version": source["version"],
        "source_sha256": source["sha256"],
        "source_vault_path": source["vault_artifact"],
        "source_url": derived["source_url"],
        "source_attribution": derived["attribution"],
        "source_notice_sha256": derived["notice_sha256"],
        "notice_sha256": derived["notice_sha256"],
    }
    for field, expected in expected_source_fields.items():
        if manifest.get(field) != expected:
            raise QuranPackSemanticError(
                f"quran-core manifest {field} does not match preserved source"
            )

    artifact = _safe_pack_file(root, manifest.get("artifact_path"), "artifact_path")
    notice_path = _safe_pack_file(root, manifest.get("notice_path"), "notice_path")
    if artifact.parent != notice_path.parent:
        raise QuranPackSemanticError(
            "quran-core notice must travel beside the SQLite artifact"
        )
    if notice_path.read_text(encoding="utf-8") != derived["notice"]:
        raise QuranPackSemanticError(
            "quran-core NOTICE.txt does not exactly match preserved source notice"
        )
    return artifact, notice_path


def _schema_rows(connection: sqlite3.Connection) -> list[tuple[str, str, str, str]]:
    return connection.execute(
        """
        SELECT type, name, tbl_name, sql
        FROM sqlite_schema
        WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
        ORDER BY type, name
        """
    ).fetchall()


def _verify_canonical_schema(root: Path, connection: sqlite3.Connection) -> None:
    schema_path = root / "schemas" / "content_v1.sql"
    if not schema_path.is_file():
        raise QuranPackSemanticError("missing canonical schemas/content_v1.sql")

    canonical = sqlite3.connect(":memory:")
    try:
        canonical.executescript(schema_path.read_text(encoding="utf-8"))
        expected = _schema_rows(canonical)
    finally:
        canonical.close()

    actual = _schema_rows(connection)
    if actual != expected:
        expected_names = {(kind, name) for kind, name, _, _ in expected}
        actual_names = {(kind, name) for kind, name, _, _ in actual}
        missing = sorted(expected_names - actual_names)
        extra = sorted(actual_names - expected_names)
        changed = sorted(
            (kind, name)
            for kind, name, _, sql in actual
            for ekind, ename, _, esql in expected
            if kind == ekind and name == ename and sql != esql
        )
        raise QuranPackSemanticError(
            "quran-core schema does not match canonical content_v1.sql "
            f"(missing={missing}, extra={extra}, changed={changed})"
        )


def _verify_metadata(
    connection: sqlite3.Connection,
    manifest: dict[str, Any],
    source: dict[str, Any],
    derived: dict[str, str],
) -> None:
    rows = connection.execute(
        "SELECT key, value FROM pack_metadata ORDER BY key"
    ).fetchall()
    metadata = {key: value for key, value in rows}
    if len(metadata) != len(rows):
        raise QuranPackSemanticError("duplicate pack_metadata keys detected")

    expected = {
        "pack_id": PACK_ID,
        "schema_version": "1",
        "content_version": str(manifest["content_version"]),
        "source_id": SOURCE_ID,
        "source_version": str(source["version"]),
        "source_sha256": str(source["sha256"]),
        "source_url": derived["source_url"],
        "source_attribution": derived["attribution"],
        "source_notice": derived["notice"],
        "source_notice_sha256": derived["notice_sha256"],
        "importer_version": str(manifest["importer_version"]),
        "search_normalization_version": SEARCH_NORMALIZATION_VERSION,
        "quran_coordinate_count": str(manifest["record_count"]),
    }
    if metadata != expected:
        missing = sorted(set(expected) - set(metadata))
        extra = sorted(set(metadata) - set(expected))
        mismatched = sorted(
            key
            for key in set(expected) & set(metadata)
            if metadata[key] != expected[key]
        )
        raise QuranPackSemanticError(
            "quran-core pack_metadata mismatch "
            f"(missing={missing}, extra={extra}, mismatched={mismatched})"
        )


def _verify_source_assertion(
    connection: sqlite3.Connection,
    source: dict[str, Any],
    derived: dict[str, str],
) -> None:
    rows = connection.execute(
        """
        SELECT source_assertion_id, source_id, source_version, source_sha256,
               assertion_type, payload_json
        FROM source_assertion
        ORDER BY source_assertion_id
        """
    ).fetchall()
    if len(rows) != 1:
        raise QuranPackSemanticError(
            f"expected exactly one Quran source assertion, found {len(rows)}"
        )

    identity = rows[0][:5]
    expected_identity = (
        SOURCE_ASSERTION_ID,
        SOURCE_ID,
        source["version"],
        source["sha256"],
        "quran_text",
    )
    if identity != expected_identity:
        raise QuranPackSemanticError("quran-core source assertion identity mismatch")

    try:
        payload = json.loads(rows[0][5])
    except json.JSONDecodeError as exc:
        raise QuranPackSemanticError(
            "quran-core source assertion payload is not valid JSON"
        ) from exc

    expected_payload = {
        "role": "quran-source-text",
        "vault_artifact": source["vault_artifact"],
        "licence_snapshot": source["licence_snapshot"],
        "provenance": source["provenance"],
        "source_url": derived["source_url"],
        "source_attribution": derived["attribution"],
        "source_notice_sha256": derived["notice_sha256"],
    }
    if payload != expected_payload:
        raise QuranPackSemanticError("quran-core source assertion payload mismatch")


def _verify_quran_rows(connection: sqlite3.Connection, expected_rows: list) -> None:
    actual_rows = connection.execute(
        """
        SELECT ayah_id, surah, ayah, original_text,
               search_unicode, search_diacritic_free, source_assertion_id
        FROM quran_ayah
        ORDER BY surah, ayah
        """
    ).fetchall()
    if len(actual_rows) != len(expected_rows):
        raise QuranPackSemanticError(
            f"quran-core row count mismatch: "
            f"expected {len(expected_rows)}, found {len(actual_rows)}"
        )

    for index, (actual, expected) in enumerate(
        zip(actual_rows, expected_rows), start=1
    ):
        expected_tuple = (
            expected.ayah_id,
            expected.surah,
            expected.ayah,
            expected.original_text,
            normalize_search_unicode(expected.original_text),
            normalize_search_diacritic_free(expected.original_text),
            SOURCE_ASSERTION_ID,
        )
        if actual != expected_tuple:
            raise QuranPackSemanticError(
                "quran-core semantic mismatch at "
                f"{expected.surah}:{expected.ayah} (row {index})"
            )


def _verify_no_unexpected_evidence(connection: sqlite3.Connection) -> None:
    empty_tables = (
        "quran_token",
        "quran_segment",
        "lexeme",
        "sense",
        "hadith_edition",
        "hadith_record",
        "citation",
        "grade_assertion",
        "occurrence",
        "narration_cluster",
        "narration_cluster_member",
    )
    non_empty = []
    for table in empty_tables:
        count = connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        if count:
            non_empty.append((table, count))
    if non_empty:
        raise QuranPackSemanticError(
            f"quran-core contains unexpected evidence rows: {non_empty}"
        )


def verify_quran_core_pack(
    root: Path,
    manifest: dict[str, Any],
    artifact: Path | None = None,
) -> None:
    root = root.resolve()
    release = _release_expectations(manifest)
    source, expected_rows, derived = _source_evidence(root)
    manifest_artifact, _ = _verify_manifest_contract(
        root, manifest, source, derived, release
    )
    artifact = (artifact or manifest_artifact).resolve()
    if artifact != manifest_artifact:
        raise QuranPackSemanticError(
            "pack gate artifact does not match manifest artifact_path"
        )

    try:
        connection = sqlite3.connect(
            artifact.as_uri() + "?mode=ro&immutable=1",
            uri=True,
        )
    except sqlite3.Error as exc:
        raise QuranPackSemanticError(
            f"cannot open quran-core SQLite pack read-only: {exc}"
        ) from exc

    try:
        connection.execute("PRAGMA query_only = ON")
        integrity = connection.execute("PRAGMA integrity_check").fetchall()
        if integrity != [("ok",)]:
            raise QuranPackSemanticError(
                f"quran-core SQLite integrity_check failed: {integrity[:3]}"
            )
        foreign_keys = connection.execute("PRAGMA foreign_key_check").fetchall()
        if foreign_keys:
            raise QuranPackSemanticError(
                f"quran-core foreign_key_check failed: {foreign_keys[:3]}"
            )

        _verify_canonical_schema(root, connection)
        _verify_metadata(connection, manifest, source, derived)
        _verify_source_assertion(connection, source, derived)
        _verify_quran_rows(connection, expected_rows)
        _verify_no_unexpected_evidence(connection)
    except sqlite3.Error as exc:
        raise QuranPackSemanticError(
            f"quran-core SQLite semantic verification failed: {exc}"
        ) from exc
    finally:
        connection.close()


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    manifest_path = (
        Path(sys.argv[1])
        if len(sys.argv) == 2
        else root / "content-packs" / "quran-core" / "1.0.2" / "manifest.json"
    )
    if len(sys.argv) > 2:
        raise SystemExit(
            "usage: python tools/verify_quran_core_pack.py "
            "[content-packs/quran-core/1.0.2/manifest.json]"
        )
    if not manifest_path.is_absolute():
        manifest_path = root / manifest_path
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    verify_quran_core_pack(root, manifest)
    print("Quran core semantic verification OK")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError, QuranPackSemanticError) as exc:
        print(f"Quran core semantic verification FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
