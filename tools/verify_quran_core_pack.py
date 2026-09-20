#!/usr/bin/env python3
"""Independent semantic verifier for provenance-bound quran-core packs.

The manifest/artifact hashes identify exact bytes. This module verifies a
separate property: a schema-v2 quran-core SQLite pack still represents the
production-approved Source Vault evidence and the reviewed canonical schema.
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
SEMANTIC_SCHEMA_VERSION = 2
SOURCE_ASSERTION_ID = "sa:quran.tanzil.uthmani.v1.1"


class QuranPackSemanticError(RuntimeError):
    pass


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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
    provenance_path = root / source["provenance"]
    licence_path = root / source["licence_snapshot"]

    if not provenance_path.is_file() or not licence_path.is_file():
        raise QuranPackSemanticError("Source Vault licence/provenance file is missing")
    if _sha256_file(provenance_path) != source.get("provenance_sha256"):
        raise QuranPackSemanticError("Source Vault provenance SHA-256 mismatch")
    if _sha256_file(licence_path) != source.get("licence_sha256"):
        raise QuranPackSemanticError("Source Vault licence SHA-256 mismatch")

    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    attribution = provenance.get("attribution")
    source_url = provenance.get("original_url")
    licence_url = provenance.get("licence_url")
    if not isinstance(attribution, str) or not attribution:
        raise QuranPackSemanticError("source provenance is missing attribution")
    if source_url != source.get("original_url"):
        raise QuranPackSemanticError(
            "source provenance URL does not match Source Vault registry"
        )
    if not isinstance(licence_url, str) or not licence_url:
        raise QuranPackSemanticError("source provenance is missing licence_url")

    derived = {
        "notice": notice,
        "notice_sha256": hashlib.sha256(notice.encode("utf-8")).hexdigest(),
        "attribution": attribution,
        "source_url": source_url,
        "licence_url": licence_url,
    }
    return source, rows, derived


def _verify_manifest_contract(
    root: Path,
    manifest: dict[str, Any],
    source: dict[str, Any],
    expected_rows: list,
    derived: dict[str, str],
) -> Path:
    if manifest.get("pack_id") != PACK_ID:
        raise QuranPackSemanticError(
            f"semantic verifier only supports pack_id={PACK_ID!r}"
        )
    if manifest.get("schema_version") != SEMANTIC_SCHEMA_VERSION:
        raise QuranPackSemanticError(
            f"quran-core semantic verification requires schema_version "
            f"{SEMANTIC_SCHEMA_VERSION}"
        )
    if manifest.get("source_id") != SOURCE_ID:
        raise QuranPackSemanticError("quran-core source_id mismatch")
    if manifest.get("record_count") != len(expected_rows):
        raise QuranPackSemanticError(
            "quran-core manifest record_count does not match Source Vault rows"
        )
    if manifest.get("dependencies") != []:
        raise QuranPackSemanticError(
            "quran-core must not claim undeclared pack dependencies"
        )
    if manifest.get("search_normalization_version") != SEARCH_NORMALIZATION_VERSION:
        raise QuranPackSemanticError(
            "quran-core search normalization version mismatch"
        )
    if not isinstance(manifest.get("content_version"), str) or not manifest["content_version"]:
        raise QuranPackSemanticError("quran-core content_version is missing")
    if not isinstance(manifest.get("importer_version"), str) or not manifest["importer_version"]:
        raise QuranPackSemanticError("quran-core importer_version is missing")

    expected = {
        "source_name": source["source_name"],
        "source_version": source["version"],
        "source_vault_path": source["vault_artifact"],
        "source_sha256": source["sha256"],
        "licence": source["licence_id"],
        "source_url": derived["source_url"],
        "source_attribution": derived["attribution"],
        "source_licence_url": derived["licence_url"],
        "source_licence_sha256": source["licence_sha256"],
        "source_provenance_sha256": source["provenance_sha256"],
        "source_notice_sha256": derived["notice_sha256"],
        "notice_sha256": derived["notice_sha256"],
        "source_artifact_name": Path(source["vault_artifact"]).name,
    }
    for field, value in expected.items():
        if manifest.get(field) != value:
            raise QuranPackSemanticError(
                f"quran-core manifest {field} does not match Source Vault evidence"
            )

    artifact = _safe_pack_file(root, manifest.get("artifact_path"), "artifact_path")
    notice_path = _safe_pack_file(root, manifest.get("notice_path"), "notice_path")
    manifest_path = root / "content-packs" / PACK_ID / manifest["content_version"] / "manifest.json"
    # Do not require the caller's manifest to live at this conventional path;
    # do require artifact + notice to be siblings, matching pack locality.
    if artifact.parent != notice_path.parent:
        raise QuranPackSemanticError(
            "quran-core notice must travel beside the SQLite artifact"
        )
    if notice_path.read_text(encoding="utf-8") != derived["notice"]:
        raise QuranPackSemanticError(
            "quran-core NOTICE.txt does not exactly match preserved source notice"
        )
    return artifact


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
    if actual == expected:
        return

    expected_names = {(kind, name) for kind, name, _, _ in expected}
    actual_names = {(kind, name) for kind, name, _, _ in actual}
    changed = sorted(
        (kind, name)
        for kind, name, _, sql in actual
        for ekind, ename, _, esql in expected
        if kind == ekind and name == ename and sql != esql
    )
    raise QuranPackSemanticError(
        "quran-core schema does not match canonical content_v1.sql "
        f"(missing={sorted(expected_names - actual_names)}, "
        f"extra={sorted(actual_names - expected_names)}, changed={changed})"
    )


def _verify_metadata(
    connection: sqlite3.Connection,
    manifest: dict[str, Any],
    source: dict[str, Any],
    derived: dict[str, str],
    row_count: int,
) -> None:
    rows = connection.execute(
        "SELECT key, value FROM pack_metadata ORDER BY key"
    ).fetchall()
    metadata = {key: value for key, value in rows}
    if len(metadata) != len(rows):
        raise QuranPackSemanticError("duplicate pack_metadata keys detected")

    required = {
        "pack_id": PACK_ID,
        "schema_version": str(SEMANTIC_SCHEMA_VERSION),
        "content_version": manifest["content_version"],
        "source_id": SOURCE_ID,
        "source_version": source["version"],
        "source_sha256": source["sha256"],
        "source_url": derived["source_url"],
        "source_attribution": derived["attribution"],
        "source_licence_url": derived["licence_url"],
        "source_licence_sha256": source["licence_sha256"],
        "source_provenance_sha256": source["provenance_sha256"],
        "source_notice": derived["notice"],
        "source_notice_sha256": derived["notice_sha256"],
        "importer_version": manifest["importer_version"],
        "search_normalization_version": SEARCH_NORMALIZATION_VERSION,
        "quran_coordinate_count": str(row_count),
    }
    mismatched = [key for key, value in required.items() if metadata.get(key) != value]
    if mismatched:
        raise QuranPackSemanticError(
            f"quran-core required pack_metadata mismatch: {mismatched}"
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

    if rows[0][:5] != (
        SOURCE_ASSERTION_ID,
        SOURCE_ID,
        source["version"],
        source["sha256"],
        "quran_text",
    ):
        raise QuranPackSemanticError("quran-core source assertion identity mismatch")

    payload = json.loads(rows[0][5])
    expected_payload = {
        "role": "quran-source-text",
        "vault_artifact": source["vault_artifact"],
        "licence_snapshot": source["licence_snapshot"],
        "provenance": source["provenance"],
        "source_url": derived["source_url"],
        "source_attribution": derived["attribution"],
        "source_licence_url": derived["licence_url"],
        "source_licence_sha256": source["licence_sha256"],
        "source_provenance_sha256": source["provenance_sha256"],
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
            f"quran-core row count mismatch: expected {len(expected_rows)}, "
            f"found {len(actual_rows)}"
        )

    for index, (actual, expected) in enumerate(zip(actual_rows, expected_rows), start=1):
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
                f"quran-core semantic mismatch at "
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
    non_empty = [
        (table, connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])
        for table in empty_tables
    ]
    non_empty = [(table, count) for table, count in non_empty if count]
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
    source, expected_rows, derived = _source_evidence(root)
    manifest_artifact = _verify_manifest_contract(
        root, manifest, source, expected_rows, derived
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
        _verify_metadata(connection, manifest, source, derived, len(expected_rows))
        _verify_source_assertion(connection, source, derived)
        _verify_quran_rows(connection, expected_rows)
        _verify_no_unexpected_evidence(connection)
    except (json.JSONDecodeError, sqlite3.Error) as exc:
        raise QuranPackSemanticError(
            f"quran-core SQLite semantic verification failed: {exc}"
        ) from exc
    finally:
        connection.close()


def _version_key(path: Path) -> tuple[int, ...]:
    try:
        return tuple(int(part) for part in path.parent.name.split("."))
    except ValueError as exc:
        raise QuranPackSemanticError(
            f"non-numeric quran-core content version: {path.parent.name}"
        ) from exc


def latest_schema_v2_manifest(root: Path) -> Path:
    candidates = []
    for path in (root / "content-packs" / PACK_ID).glob("*/manifest.json"):
        try:
            manifest = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if manifest.get("schema_version") == SEMANTIC_SCHEMA_VERSION:
            candidates.append(path)
    if not candidates:
        raise QuranPackSemanticError("no schema-v2 quran-core manifest found")
    return max(candidates, key=_version_key)


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    if len(sys.argv) > 2:
        raise SystemExit(
            "usage: python tools/verify_quran_core_pack.py [manifest.json]"
        )
    manifest_path = (
        Path(sys.argv[1]) if len(sys.argv) == 2 else latest_schema_v2_manifest(root)
    )
    if not manifest_path.is_absolute():
        manifest_path = root / manifest_path
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    verify_quran_core_pack(root, manifest)
    print(f"Quran core semantic verification OK ({manifest['content_version']})")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError, QuranPackSemanticError) as exc:
        print(f"Quran core semantic verification FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
