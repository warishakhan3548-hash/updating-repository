#!/usr/bin/env python3
"""Independent semantic verifier for the immutable quran-core runtime pack.

The outer pack SHA-256 proves which SQLite bytes are being handled. This verifier
proves a different property: those bytes still faithfully represent the
production-approved Quran Source Vault snapshot.
"""
from __future__ import annotations

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
    load_production_source,
    normalize_search_diacritic_free,
    normalize_search_unicode,
)

PACK_ID = "quran-core"
SOURCE_ASSERTION_ID = "sa:quran.tanzil.uthmani.v1.1"

# Release-specific expectations are intentionally explicit. A future pack version
# must be reviewed and added here instead of silently inheriting old assumptions.
SUPPORTED_RELEASES = {
    "1.0.1": {
        "importer_version": "quran-core-importer-2",
        "record_count": 6236,
        "notice_sha256": "83cc1310c83bf3c67fb9b403c5939b4109a2cea9295fe6f610a756846ad9b7be",
    }
}


class QuranPackSemanticError(RuntimeError):
    pass


def _artifact_from_manifest(root: Path, manifest: dict[str, Any]) -> Path:
    raw = manifest.get("artifact_path")
    if not isinstance(raw, str) or not raw:
        raise QuranPackSemanticError("quran-core manifest is missing artifact_path")
    rel = Path(raw)
    if (
        rel.is_absolute()
        or ".." in rel.parts
        or not rel.parts
        or rel.parts[0] != "content-packs"
    ):
        raise QuranPackSemanticError(
            "quran-core artifact_path must stay under content-packs/"
        )
    artifact = root / rel
    if not artifact.is_file():
        raise QuranPackSemanticError(f"missing quran-core artifact: {rel}")
    try:
        artifact.resolve().relative_to((root / "content-packs").resolve())
    except ValueError as exc:
        raise QuranPackSemanticError(
            "quran-core artifact resolves outside content-packs/"
        ) from exc
    return artifact


def _release_expectations(manifest: dict[str, Any]) -> dict[str, Any]:
    version = manifest.get("content_version")
    expected = SUPPORTED_RELEASES.get(version)
    if expected is None:
        raise QuranPackSemanticError(
            "unsupported quran-core content_version for semantic verification: "
            f"{version!r}"
        )
    return expected


def _verify_manifest_contract(
    manifest: dict[str, Any],
    release: dict[str, Any],
) -> None:
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
            "quran-core 1.0.x must not claim undeclared pack dependencies"
        )
    if manifest.get("search_normalization_version") != SEARCH_NORMALIZATION_VERSION:
        raise QuranPackSemanticError(
            "quran-core search normalization version mismatch"
        )
    if manifest.get("notice_sha256") != release["notice_sha256"]:
        raise QuranPackSemanticError(
            "quran-core attribution notice is not the reviewed release notice"
        )

    artifact = Path(str(manifest.get("artifact_path", "")))
    notice = Path(str(manifest.get("notice_path", "")))
    if artifact.parent != notice.parent or notice.name != "NOTICE.txt":
        raise QuranPackSemanticError(
            "quran-core attribution notice must travel beside the SQLite artifact"
        )


def _expect_exact_metadata(
    connection: sqlite3.Connection,
    manifest: dict[str, Any],
    source: dict[str, Any],
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

    (
        assertion_id,
        source_id,
        source_version,
        source_sha256,
        assertion_type,
        payload_json,
    ) = rows[0]
    if (
        assertion_id != SOURCE_ASSERTION_ID
        or source_id != SOURCE_ID
        or source_version != source["version"]
        or source_sha256 != source["sha256"]
        or assertion_type != "quran_text"
    ):
        raise QuranPackSemanticError("quran-core source assertion identity mismatch")

    try:
        payload = json.loads(payload_json)
    except json.JSONDecodeError as exc:
        raise QuranPackSemanticError(
            "quran-core source assertion payload is not valid JSON"
        ) from exc

    expected_payload = {
        "role": "quran-source-text",
        "vault_artifact": source["vault_artifact"],
        "licence_snapshot": source["licence_snapshot"],
        "provenance": source["provenance"],
    }
    if payload != expected_payload:
        raise QuranPackSemanticError("quran-core source assertion payload mismatch")


def _verify_schema_guards(connection: sqlite3.Connection) -> None:
    required_triggers = {
        "source_assertion_no_update",
        "source_assertion_no_delete",
        "quran_ayah_no_update",
        "quran_ayah_no_delete",
    }
    found = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_schema WHERE type='trigger'"
        ).fetchall()
    }
    missing = sorted(required_triggers - found)
    if missing:
        raise QuranPackSemanticError(
            f"quran-core is missing Evidence Plane immutability triggers: {missing}"
        )


def _verify_no_unexpected_evidence(connection: sqlite3.Connection) -> None:
    # quran-core 1.0.1 deliberately contains only ayah-level Quran evidence.
    # Morphology, lexemes and Hadith evidence are blocked behind independent
    # source/licence gates and must not leak into this pack.
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
            f"quran-core 1.0.1 contains unexpected evidence rows: {non_empty}"
        )


def verify_quran_core_pack(
    root: Path,
    manifest: dict[str, Any],
    artifact: Path | None = None,
) -> None:
    root = root.resolve()
    release = _release_expectations(manifest)
    _verify_manifest_contract(manifest, release)

    source, _, expected_rows = load_production_source(root)
    artifact = (artifact or _artifact_from_manifest(root, manifest)).resolve()
    try:
        artifact.relative_to((root / "content-packs").resolve())
    except ValueError as exc:
        raise QuranPackSemanticError(
            "quran-core artifact resolves outside content-packs/"
        ) from exc

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

        _expect_exact_metadata(connection, manifest, source)
        _verify_source_assertion(connection, source)
        _verify_schema_guards(connection)

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

        _verify_no_unexpected_evidence(connection)
    except sqlite3.Error as exc:
        raise QuranPackSemanticError(
            f"quran-core SQLite semantic verification failed: {exc}"
        ) from exc
    finally:
        connection.close()


def main() -> None:
    if len(sys.argv) not in {1, 2}:
        raise SystemExit(
            "usage: python tools/verify_quran_core_pack.py "
            "[content-packs/quran-core/1.0.1/manifest.json]"
        )
    root = Path(__file__).resolve().parents[1]
    manifest_path = (
        Path(sys.argv[1])
        if len(sys.argv) == 2
        else root / "content-packs" / "quran-core" / "1.0.1" / "manifest.json"
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
