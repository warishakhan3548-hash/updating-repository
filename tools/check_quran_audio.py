#!/usr/bin/env python3
"""Fail-closed verifier for an APK-bundled Quran word-audio pack.

This script is intentionally network-free. It validates the local source-vault pack against the
canonical Quran SQLite word identities produced by build_content.py. A complete pack must contain
exactly one audio file for every canonical :W: word and no unexpected word-audio files.
"""
import argparse
import hashlib
import json
import sqlite3
from pathlib import Path


def file_hash(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def expected_rows(db_path: Path):
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        rows = list(db.execute(
            "SELECT id,ayah_id,position FROM word "
            "WHERE position>0 AND id LIKE '%:W:%' ORDER BY ayah_id,position"
        ))
    finally:
        db.close()
    return rows


def expected_relative(ayah_id: str, position: int, root: str, extension: str) -> str:
    parts = ayah_id.split(":")
    if len(parts) != 3 or parts[0] != "Q":
        raise ValueError(f"Invalid canonical ayah id: {ayah_id}")
    surah, ayah = int(parts[1]), int(parts[2])
    return f"{root}/{surah:03d}/{surah:03d}_{ayah:03d}_{position:03d}.{extension}"


def surah_digest(source: Path, relatives):
    h = hashlib.sha256()
    for rel in sorted(relatives):
        path = source / rel
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        h.update(file_hash(path).encode("ascii"))
        h.update(b"\n")
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path,
                        help="source-vault/quran-audio/active directory")
    parser.add_argument("--quran-db", required=True, type=Path)
    args = parser.parse_args()

    source = args.source.resolve()
    manifest_path = source / "quran-audio" / "manifest.json"
    if not manifest_path.is_file():
        raise SystemExit("Missing quran-audio/manifest.json")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 1:
        raise SystemExit("Unsupported Quran audio manifest schema")
    if manifest.get("runtime_network_required") is not False:
        raise SystemExit("Quran audio pack must not require runtime network access")
    if manifest.get("coverage_complete") is not True:
        raise SystemExit("Incomplete Quran word-audio packs may not be bundled as active")
    if not args.quran_db.is_file():
        raise SystemExit("Canonical quran.sqlite is missing; prepareContentPack must run first")

    root = str(manifest.get("asset_root") or "")
    extension = str(manifest.get("file_extension") or "").lower()
    if not root.startswith("quran-audio/") or ".." in Path(root).parts:
        raise SystemExit("Unsafe Quran audio asset_root")
    if not extension.isalnum() or not 2 <= len(extension) <= 6:
        raise SystemExit("Invalid Quran audio file extension")

    license_files = manifest.get("license_files")
    if not isinstance(license_files, list) or not license_files:
        raise SystemExit("Quran audio pack must retain license/provenance evidence")
    for rel in license_files:
        path = source / rel
        if not path.is_file() or path.stat().st_size < 1:
            raise SystemExit(f"Missing license/provenance evidence: {rel}")

    rows = expected_rows(args.quran_db)
    expected = set()
    by_surah = {}
    for word_id, ayah_id, position in rows:
        if not word_id.startswith(ayah_id + ":W:"):
            raise SystemExit(f"Canonical word identity mismatch: {word_id}")
        rel = expected_relative(ayah_id, int(position), root, extension)
        expected.add(rel)
        surah = int(ayah_id.split(":")[1])
        by_surah.setdefault(surah, []).append(rel)

    declared_count = int(manifest.get("word_count") or 0)
    if declared_count != len(expected):
        raise SystemExit(f"Word-audio count mismatch: manifest={declared_count}, canonical={len(expected)}")

    missing = []
    tiny = []
    for rel in sorted(expected):
        path = source / rel
        if not path.is_file():
            missing.append(rel)
            if len(missing) >= 20:
                break
        elif path.stat().st_size < 32:
            tiny.append(rel)
            if len(tiny) >= 20:
                break
    if missing:
        raise SystemExit("Missing canonical word audio: " + ", ".join(missing))
    if tiny:
        raise SystemExit("Suspiciously small word audio: " + ", ".join(tiny))

    audio_root = source / root
    actual = {
        str(path.relative_to(source))
        for path in audio_root.rglob(f"*.{extension}")
        if path.is_file()
    }
    extra = sorted(actual - expected)
    if extra:
        raise SystemExit("Unexpected word audio files: " + ", ".join(extra[:20]))
    if len(actual) != len(expected):
        raise SystemExit(f"Audio file coverage mismatch: actual={len(actual)}, expected={len(expected)}")

    locked = manifest.get("surah_sha256")
    if not isinstance(locked, dict) or len(locked) != 114:
        raise SystemExit("Manifest must pin 114 per-surah audio digests")
    for surah in range(1, 115):
        key = f"{surah:03d}"
        actual_hash = surah_digest(source, by_surah.get(surah, []))
        if locked.get(key) != actual_hash:
            raise SystemExit(f"Surah {surah} audio digest mismatch")

    print(json.dumps({
        "status": "PASS",
        "pack_id": manifest.get("pack_id"),
        "style": manifest.get("style"),
        "word_files": len(actual),
        "runtime_network_required": False,
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
