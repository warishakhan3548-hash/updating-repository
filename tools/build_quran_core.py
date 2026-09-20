#!/usr/bin/env python3
"""Build the deterministic Quran core SQLite pack from the pinned Source Vault artifact."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import sys

# Support both "python -m tools.build_quran_core" and direct CLI execution.
# Direct script execution otherwise puts tools/ rather than the repository root on sys.path.
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
CONTENT_VERSION = "1.0.1"
IMPORTER_VERSION = "quran-core-importer-2"
SOURCE_ASSERTION_ID = "sa:quran.tanzil.uthmani.v1.1"


class QuranPackError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_pack(root: Path, output_dir: Path) -> tuple[Path, Path]:
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
    manifest_path = output_dir / "manifest.json"
    if db_path.exists() or manifest_path.exists():
        raise QuranPackError(
            f"immutable pack target already exists: {relative_dir.as_posix()}"
        )
    output_dir.mkdir(parents=True, exist_ok=True)

    source, artifact, rows = load_production_source(root)
    source_notice = extract_tanzil_notice(artifact)
    source_notice_sha256 = hashlib.sha256(source_notice.encode("utf-8")).hexdigest()
    provenance_path = root / source["provenance"]
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    source_attribution = provenance.get("attribution")
    source_url = provenance.get("original_url")
    if not isinstance(source_attribution, str) or not source_attribution:
        raise QuranPackError("source provenance is missing runtime attribution")
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
            "schema_version": "1",
            "content_version": CONTENT_VERSION,
            "source_id": SOURCE_ID,
            "source_version": source["version"],
            "source_sha256": source["sha256"],
            "source_name": source["source_name"],
            "source_url": source_url,
            "source_attribution": source_attribution,
            "source_notice": source_notice,
            "source_notice_sha256": source_notice_sha256,
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

    built_hash = sha256_file(db_path)
    built_size = db_path.stat().st_size
    manifest = {
        "pack_id": PACK_ID,
        "schema_version": 1,
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
        "source_artifact_name": artifact.name,
        "search_normalization_version": SEARCH_NORMALIZATION_VERSION,
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
        "--output",
        type=Path,
        default=Path("content-packs/quran-core/1.0.1"),
        help="pack directory, relative to repository root",
    )
    args = parser.parse_args()
    db_path, manifest_path = build_pack(args.root, args.output)
    print(f"Built {db_path}")
    print(f"Manifest {manifest_path}")


if __name__ == "__main__":
    main()
