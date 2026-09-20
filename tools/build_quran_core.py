#!/usr/bin/env python3
"""Build the Quran core SQLite pack from the canonical Quran artifact."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import sqlite3
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.quran_canonical import (
    DEFAULT_CANONICAL_MANIFEST,
    load_canonical,
    sha256_file as sha256_canonical_file,
)
from tools.quran_core import (
    SEARCH_NORMALIZATION_VERSION,
    SOURCE_ID,
    extract_tanzil_notice,
    normalize_search_diacritic_free,
    normalize_search_unicode,
)

PACK_ID = "quran-core"
CONTENT_VERSION = "1.1.0"
MANIFEST_SCHEMA_VERSION = 2
CONTENT_SCHEMA_VERSION = 1
IMPORTER_VERSION = "quran-core-importer-5"
SOURCE_ASSERTION_ID = "sa:quran.tanzil.uthmani.v1.1"


class QuranPackError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_pack(
    root: Path,
    output_dir: Path,
    canonical_manifest: Path = DEFAULT_CANONICAL_MANIFEST,
) -> tuple[Path, Path]:
    root = root.resolve()
    if not output_dir.is_absolute():
        output_dir = root / output_dir
    output_dir = output_dir.resolve()
    try:
        relative_dir = output_dir.relative_to(root)
    except ValueError as exc:
        raise QuranPackError("output directory must remain inside repository root") from exc
    if not relative_dir.parts or relative_dir.parts[0] != "content-packs":
        raise QuranPackError("output directory must be under content-packs/")

    db_path = output_dir / "content.sqlite"
    notice_path = output_dir / "NOTICE.txt"
    manifest_path = output_dir / "manifest.json"
    if db_path.exists() or notice_path.exists() or manifest_path.exists():
        raise QuranPackError(
            f"immutable pack target already exists: {relative_dir.as_posix()}"
        )
    output_dir.mkdir(parents=True, exist_ok=True)

    canonical = load_canonical(root, canonical_manifest)
    source = canonical.source
    source_artifact = canonical.source_artifact
    rows = canonical.rows

    source_notice = extract_tanzil_notice(source_artifact)
    source_notice_sha256 = hashlib.sha256(source_notice.encode("utf-8")).hexdigest()
    provenance = json.loads((root / source["provenance"]).read_text(encoding="utf-8"))
    source_attribution = provenance.get("attribution")
    source_url = provenance.get("original_url")
    if not isinstance(source_attribution, str) or not source_attribution:
        raise QuranPackError("source provenance is missing attribution")
    if source_url != source.get("original_url"):
        raise QuranPackError("source provenance URL does not match Source Vault registry")

    schema = (root / "schemas" / "content_v1.sql").read_text(encoding="utf-8")
    connection = sqlite3.connect(db_path)
    try:
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA page_size = 4096")
        connection.executescript(schema)

        payload = json.dumps(
            {
                "role": "quran-source-text",
                "vault_artifact": source["vault_artifact"],
                "licence_snapshot": source["licence_snapshot"],
                "provenance": source["provenance"],
                "source_url": source_url,
                "source_attribution": source_attribution,
                "source_notice_sha256": source_notice_sha256,
                "canonical_artifact": canonical.manifest["artifact_path"],
                "canonical_sha256": canonical.manifest["artifact_sha256"],
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        connection.execute(
            """
            INSERT INTO source_assertion(
                source_assertion_id, source_id, source_version, source_sha256,
                assertion_type, payload_json
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                SOURCE_ASSERTION_ID,
                SOURCE_ID,
                source["version"],
                source["sha256"],
                "quran_text",
                payload,
            ),
        )

        metadata = {
            "pack_id": PACK_ID,
            "content_schema_version": str(CONTENT_SCHEMA_VERSION),
            "content_version": CONTENT_VERSION,
            "source_id": SOURCE_ID,
            "source_version": source["version"],
            "source_sha256": source["sha256"],
            "source_url": source_url,
            "source_attribution": source_attribution,
            "source_notice": source_notice,
            "source_notice_sha256": source_notice_sha256,
            "canonical_id": canonical.manifest["canonical_id"],
            "canonical_version": canonical.manifest["canonical_version"],
            "canonical_sha256": canonical.manifest["artifact_sha256"],
            "importer_version": IMPORTER_VERSION,
            "search_normalization_version": SEARCH_NORMALIZATION_VERSION,
            "quran_coordinate_count": str(len(rows)),
        }
        connection.executemany(
            "INSERT INTO pack_metadata(key, value) VALUES (?, ?)",
            sorted(metadata.items()),
        )

        connection.executemany(
            """
            INSERT INTO quran_ayah(
                ayah_id, surah, ayah, original_text,
                search_unicode, search_diacritic_free, source_assertion_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                (
                    row.ayah_id,
                    row.surah,
                    row.ayah,
                    row.original_text,
                    normalize_search_unicode(row.original_text),
                    normalize_search_diacritic_free(row.original_text),
                    SOURCE_ASSERTION_ID,
                )
                for row in rows
            ),
        )
        connection.commit()

        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise QuranPackError("SQLite integrity_check failed")
        if connection.execute("PRAGMA foreign_key_check").fetchall():
            raise QuranPackError("SQLite foreign_key_check failed")
        count = connection.execute("SELECT COUNT(*) FROM quran_ayah").fetchone()[0]
        if count != 6236:
            raise QuranPackError(f"expected 6236 Quran ayahs, built {count}")
        source_rows = connection.execute(
            "SELECT COUNT(*) FROM source_assertion WHERE source_id = ?", (SOURCE_ID,)
        ).fetchone()[0]
        if source_rows != 1:
            raise QuranPackError("expected exactly one Quran source assertion")
        stored_notice = connection.execute(
            "SELECT value FROM pack_metadata WHERE key = 'source_notice'"
        ).fetchone()
        if stored_notice is None or stored_notice[0] != source_notice:
            raise QuranPackError("runtime pack did not preserve the source notice")
    finally:
        connection.close()

    notice_path.write_text(source_notice, encoding="utf-8")
    notice_hash = sha256_file(notice_path)
    built_hash = sha256_file(db_path)
    built_size = db_path.stat().st_size
    canonical_manifest_hash = sha256_canonical_file(canonical.manifest_path)

    manifest = {
        "pack_id": PACK_ID,
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "content_schema_version": CONTENT_SCHEMA_VERSION,
        "content_version": CONTENT_VERSION,
        "source_id": SOURCE_ID,
        "source_name": source["source_name"],
        "source_version": source["version"],
        "source_vault_path": source["vault_artifact"],
        "source_sha256": source["sha256"],
        "source_url": source_url,
        "source_attribution": source_attribution,
        "source_notice_sha256": source_notice_sha256,
        "licence": source["licence_id"],
        "edition": "Uthmani",
        "importer_version": IMPORTER_VERSION,
        "artifact_path": db_path.relative_to(root).as_posix(),
        "record_count": 6236,
        "review_status": "candidate",
        "built_sha256": built_hash,
        "built_byte_size": built_size,
        "dependencies": [],
        "signature": {"status": "unsigned"},
        "notice_path": notice_path.relative_to(root).as_posix(),
        "notice_sha256": notice_hash,
        "source_artifact_name": source_artifact.name,
        "search_normalization_version": SEARCH_NORMALIZATION_VERSION,
        "canonical": {
            "canonical_id": canonical.manifest["canonical_id"],
            "canonical_version": canonical.manifest["canonical_version"],
            "generator_version": canonical.manifest["generator_version"],
            "manifest_path": canonical.manifest_path.relative_to(root).as_posix(),
            "manifest_sha256": canonical_manifest_hash,
            "artifact_path": canonical.manifest["artifact_path"],
            "artifact_sha256": canonical.manifest["artifact_sha256"],
            "artifact_byte_size": canonical.manifest["artifact_byte_size"],
            "record_count": canonical.manifest["record_count"],
        },
        "build_toolchain": {
            "python_implementation": platform.python_implementation(),
            "python_version": platform.python_version(),
            "sqlite_version": sqlite3.sqlite_version,
        },
        "byte_reproducibility_scope": (
            "Byte identity is tested only for identical canonical input, importer code, "
            "Python version and SQLite library version. The canonical JSONL hash is the "
            "long-lived semantic reproducibility anchor."
        ),
    }
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    return db_path, manifest_path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root",
    )
    parser.add_argument(
        "--canonical-manifest",
        type=Path,
        default=DEFAULT_CANONICAL_MANIFEST,
        help="canonical manifest, relative to repository root",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("content-packs/quran-core/1.1.0"),
        help="pack directory, relative to repository root",
    )
    args = parser.parse_args()
    db_path, manifest_path = build_pack(
        args.root,
        args.output,
        canonical_manifest=args.canonical_manifest,
    )
    print(f"Built {db_path}")
    print(f"Manifest {manifest_path}")


if __name__ == "__main__":
    main()
