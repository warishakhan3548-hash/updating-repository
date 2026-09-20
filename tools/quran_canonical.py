#!/usr/bin/env python3
"""Canonical Quran Evidence Plane artifact between Source Vault and runtime packs."""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path

from tools.quran_core import (
    AyahRow,
    SOURCE_ID,
    expected_coordinates,
    load_production_source,
)

CANONICAL_ID = "quran-core-ayahs"
CANONICAL_VERSION = "1.0.0"
CANONICAL_SCHEMA_VERSION = 1
GENERATOR_VERSION = "quran-canonical-importer-1"
DEFAULT_CANONICAL_DIR = Path("canonical/quran-core/1.0.0")
DEFAULT_CANONICAL_MANIFEST = DEFAULT_CANONICAL_DIR / "manifest.json"
SOURCE_ASSERTION_ID = "sa:quran.tanzil.uthmani.v1.1"


class QuranCanonicalError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class CanonicalQuran:
    manifest: dict
    manifest_path: Path
    artifact_path: Path
    source: dict
    source_artifact: Path
    rows: tuple[AyahRow, ...]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _resolve_under(root: Path, raw: Path | str, prefix: str, field: str) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        path = root / path
    path = path.resolve()
    allowed = (root / prefix).resolve()
    try:
        path.relative_to(allowed)
    except ValueError as exc:
        raise QuranCanonicalError(f"{field} must remain under {prefix}/") from exc
    return path


def build_canonical(
    root: Path,
    output_dir: Path = DEFAULT_CANONICAL_DIR,
) -> tuple[Path, Path]:
    """Build an immutable, deterministic JSONL canonical Quran artifact."""
    root = root.resolve()
    output_dir = _resolve_under(root, output_dir, "canonical", "output directory")
    artifact_path = output_dir / "ayahs.jsonl"
    manifest_path = output_dir / "manifest.json"

    if artifact_path.exists() or manifest_path.exists():
        rel = output_dir.relative_to(root)
        raise QuranCanonicalError(f"immutable canonical target already exists: {rel}")

    output_dir.mkdir(parents=True, exist_ok=True)
    source, source_artifact, rows = load_production_source(root)

    with artifact_path.open("x", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            record = {
                "ayah": row.ayah,
                "ayah_id": row.ayah_id,
                "original_text": row.original_text,
                "source_assertion_id": SOURCE_ASSERTION_ID,
                "source_id": SOURCE_ID,
                "source_sha256": source["sha256"],
                "surah": row.surah,
            }
            handle.write(
                json.dumps(
                    record,
                    ensure_ascii=False,
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\n"
            )

    artifact_hash = sha256_file(artifact_path)
    manifest = {
        "canonical_id": CANONICAL_ID,
        "schema_version": CANONICAL_SCHEMA_VERSION,
        "canonical_version": CANONICAL_VERSION,
        "generator_version": GENERATOR_VERSION,
        "artifact_path": artifact_path.relative_to(root).as_posix(),
        "artifact_sha256": artifact_hash,
        "artifact_byte_size": artifact_path.stat().st_size,
        "record_count": len(rows),
        "source_id": SOURCE_ID,
        "source_name": source["source_name"],
        "source_version": source["version"],
        "source_vault_path": source["vault_artifact"],
        "source_sha256": source["sha256"],
        "source_url": source["original_url"],
        "source_licence_sha256": source["licence_sha256"],
        "source_provenance_sha256": source["provenance_sha256"],
        "licence": source["licence_id"],
        "edition": "Uthmani",
        "source_artifact_name": source_artifact.name,
    }
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    return artifact_path, manifest_path


def load_canonical(
    root: Path,
    manifest_path: Path = DEFAULT_CANONICAL_MANIFEST,
) -> CanonicalQuran:
    """Validate and load the canonical artifact, bound back to Source Vault."""
    root = root.resolve()
    manifest_path = _resolve_under(root, manifest_path, "canonical", "canonical manifest")
    if not manifest_path.is_file():
        raise QuranCanonicalError(f"missing canonical manifest: {manifest_path.relative_to(root)}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    required = {
        "canonical_id",
        "schema_version",
        "canonical_version",
        "generator_version",
        "artifact_path",
        "artifact_sha256",
        "artifact_byte_size",
        "record_count",
        "source_id",
        "source_name",
        "source_version",
        "source_vault_path",
        "source_sha256",
        "source_url",
        "source_licence_sha256",
        "source_provenance_sha256",
        "licence",
        "edition",
        "source_artifact_name",
    }
    missing = sorted(key for key in required if manifest.get(key) in (None, ""))
    if missing:
        raise QuranCanonicalError(f"canonical manifest missing fields: {missing}")
    if manifest["canonical_id"] != CANONICAL_ID:
        raise QuranCanonicalError("unexpected canonical_id")
    if manifest["schema_version"] != CANONICAL_SCHEMA_VERSION:
        raise QuranCanonicalError("unsupported canonical schema_version")
    if manifest["canonical_version"] != CANONICAL_VERSION:
        raise QuranCanonicalError("unsupported canonical_version")
    if manifest["generator_version"] != GENERATOR_VERSION:
        raise QuranCanonicalError("unexpected canonical generator_version")

    source, source_artifact, source_rows = load_production_source(root)
    expected_source = {
        "source_id": SOURCE_ID,
        "source_name": source["source_name"],
        "source_version": source["version"],
        "source_vault_path": source["vault_artifact"],
        "source_sha256": source["sha256"],
        "source_url": source["original_url"],
        "source_licence_sha256": source["licence_sha256"],
        "source_provenance_sha256": source["provenance_sha256"],
        "licence": source["licence_id"],
        "edition": "Uthmani",
        "source_artifact_name": source_artifact.name,
    }
    for field, expected in expected_source.items():
        if manifest.get(field) != expected:
            raise QuranCanonicalError(f"canonical {field} does not match Source Vault")

    artifact_path = _resolve_under(
        root, manifest["artifact_path"], "canonical", "canonical artifact"
    )
    if not artifact_path.is_file():
        raise QuranCanonicalError(
            f"missing canonical artifact: {artifact_path.relative_to(root)}"
        )
    expected_hash = manifest["artifact_sha256"]
    if not isinstance(expected_hash, str) or len(expected_hash) != 64:
        raise QuranCanonicalError("invalid canonical artifact_sha256")
    if sha256_file(artifact_path) != expected_hash:
        raise QuranCanonicalError("canonical artifact SHA-256 mismatch")
    if artifact_path.stat().st_size != manifest["artifact_byte_size"]:
        raise QuranCanonicalError("canonical artifact byte-size mismatch")

    rows: list[AyahRow] = []
    expected_keys = {
        "ayah",
        "ayah_id",
        "original_text",
        "source_assertion_id",
        "source_id",
        "source_sha256",
        "surah",
    }
    with artifact_path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise QuranCanonicalError(
                    f"invalid canonical JSON at line {line_number}"
                ) from exc
            if set(record) != expected_keys:
                raise QuranCanonicalError(
                    f"unexpected canonical fields at line {line_number}"
                )
            if record["source_id"] != SOURCE_ID:
                raise QuranCanonicalError(f"source_id drift at line {line_number}")
            if record["source_sha256"] != source["sha256"]:
                raise QuranCanonicalError(f"source_sha256 drift at line {line_number}")
            if record["source_assertion_id"] != SOURCE_ASSERTION_ID:
                raise QuranCanonicalError(
                    f"source_assertion_id drift at line {line_number}"
                )
            row = AyahRow(
                surah=record["surah"],
                ayah=record["ayah"],
                original_text=record["original_text"],
            )
            if record["ayah_id"] != row.ayah_id:
                raise QuranCanonicalError(f"ayah_id drift at line {line_number}")
            rows.append(row)

    coordinates = tuple((row.surah, row.ayah) for row in rows)
    if coordinates != expected_coordinates():
        raise QuranCanonicalError("canonical Quran coordinate sequence mismatch")
    if len(rows) != manifest["record_count"] or len(rows) != 6236:
        raise QuranCanonicalError("canonical Quran record_count mismatch")
    if tuple(rows) != tuple(source_rows):
        raise QuranCanonicalError(
            "canonical Quran text does not match preserved Source Vault artifact"
        )

    return CanonicalQuran(
        manifest=manifest,
        manifest_path=manifest_path,
        artifact_path=artifact_path,
        source=source,
        source_artifact=source_artifact,
        rows=tuple(rows),
    )
