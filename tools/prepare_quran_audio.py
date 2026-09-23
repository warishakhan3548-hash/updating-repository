#!/usr/bin/env python3
"""Prepare a deterministic, website-independent Quran word-audio pack from local files.

This tool performs no download. Point --source at an already acquired word-audio style directory
whose layout is SURAH/SURAH_AYAH_WORD.<extension>. It copies only canonical Quran :W: words,
retains license/provenance evidence, pins 114 per-surah SHA-256 digests, and atomically installs
the result under source-vault/quran-audio/active.
"""
import argparse
import hashlib
import json
import shutil
import sqlite3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def file_hash(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def rows(db_path: Path):
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        return list(db.execute(
            "SELECT id,ayah_id,position FROM word "
            "WHERE position>0 AND id LIKE '%:W:%' ORDER BY ayah_id,position"
        ))
    finally:
        db.close()


def source_file(source: Path, ayah_id: str, position: int, extension: str) -> Path:
    _, s, a = ayah_id.split(":")
    surah, ayah = int(s), int(a)
    return source / f"{surah:03d}" / f"{surah:03d}_{ayah:03d}_{position:03d}.{extension}"


def destination_rel(ayah_id: str, position: int, extension: str) -> str:
    _, s, a = ayah_id.split(":")
    surah, ayah = int(s), int(a)
    return f"quran-audio/word/{surah:03d}/{surah:03d}_{ayah:03d}_{position:03d}.{extension}"


def digest_group(stage: Path, relatives):
    h = hashlib.sha256()
    for rel in sorted(relatives):
        path = stage / rel
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        h.update(file_hash(path).encode("ascii"))
        h.update(b"\n")
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path,
                        help="Local style directory containing 001/001_001_001.opus etc.")
    parser.add_argument("--quran-db", type=Path, default=ROOT / "app/src/main/assets/quran.sqlite")
    parser.add_argument("--output", type=Path, default=ROOT / "source-vault/quran-audio/active")
    parser.add_argument("--license-evidence", required=True, type=Path)
    parser.add_argument("--source-name", required=True)
    parser.add_argument("--source-version", required=True)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--license", required=True)
    parser.add_argument("--style", default="muallim")
    parser.add_argument("--extension", default="opus")
    args = parser.parse_args()

    source = args.source.resolve()
    quran_db = args.quran_db.resolve()
    output = args.output.resolve()
    evidence = args.license_evidence.resolve()
    extension = args.extension.lower().strip(".")

    if not quran_db.is_file():
        raise SystemExit("quran.sqlite is missing; run python3 tools/build_content.py first")
    if not evidence.is_file():
        raise SystemExit("License/provenance evidence file does not exist")
    if not extension.isalnum() or not 2 <= len(extension) <= 6:
        raise SystemExit("Invalid audio extension")

    canonical = rows(quran_db)
    missing = []
    for _, ayah_id, position in canonical:
        src = source_file(source, ayah_id, int(position), extension)
        if not src.is_file():
            missing.append(str(src))
            if len(missing) >= 20:
                break
    if missing:
        raise SystemExit("Source audio does not cover canonical word coordinates: " + ", ".join(missing))

    stage = output.with_name(output.name + ".tmp")
    old = output.with_name(output.name + ".old")
    shutil.rmtree(stage, ignore_errors=True)
    shutil.rmtree(old, ignore_errors=True)
    (stage / "quran-audio" / "word").mkdir(parents=True)
    (stage / "quran-audio" / "LICENSES").mkdir(parents=True)

    by_surah = {}
    for index, (_, ayah_id, position) in enumerate(canonical, 1):
        src = source_file(source, ayah_id, int(position), extension)
        rel = destination_rel(ayah_id, int(position), extension)
        dst = stage / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        surah = int(ayah_id.split(":")[1])
        by_surah.setdefault(surah, []).append(rel)
        if index % 5000 == 0:
            print(f"Copied {index}/{len(canonical)} word files", flush=True)

    evidence_rel = "quran-audio/LICENSES/UPSTREAM.txt"
    shutil.copy2(evidence, stage / evidence_rel)
    source_meta = {
        "source_name": args.source_name,
        "source_version": args.source_version,
        "source_url": args.source_url,
        "declared_license": args.license,
        "style": args.style,
        "format": extension,
        "note": "Audio bytes were acquired before build. Android build/runtime perform no network fetch.",
    }
    (stage / "quran-audio" / "SOURCE.json").write_text(
        json.dumps(source_meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    surah_hashes = {
        f"{surah:03d}": digest_group(stage, by_surah.get(surah, []))
        for surah in range(1, 115)
    }
    manifest = {
        "schema_version": 1,
        "pack_id": f"aaris-quran-word-audio-{args.style}-{args.source_version}",
        "source_name": args.source_name,
        "source_version": args.source_version,
        "source_url": args.source_url,
        "license": args.license,
        "license_files": [evidence_rel, "quran-audio/SOURCE.json"],
        "style": args.style,
        "file_extension": extension,
        "asset_root": "quran-audio/word",
        "word_count": len(canonical),
        "coverage_complete": True,
        "surah_sha256": surah_hashes,
        "runtime_network_required": False,
    }
    (stage / "quran-audio" / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    if output.exists():
        output.rename(old)
    stage.rename(output)
    shutil.rmtree(old, ignore_errors=True)
    print(json.dumps({
        "status": "PREPARED",
        "output": str(output),
        "word_files": len(canonical),
        "style": args.style,
        "runtime_network_required": False,
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
