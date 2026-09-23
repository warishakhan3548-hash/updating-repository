#!/usr/bin/env python3
"""Network-free verifier for the compact APK-bundled Quran word-audio pack."""
import argparse
import hashlib
import json
import sqlite3
from pathlib import Path

MAX_SURAH_PACK_BYTES = 95 * 1024 * 1024
MAX_TOTAL_PACK_BYTES = 650 * 1024 * 1024


def file_hash(path: Path) -> str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda:f.read(1024*1024),b""):
            h.update(chunk)
    return h.hexdigest()


def canonical(db_path: Path):
    db=sqlite3.connect(f"file:{db_path}?mode=ro",uri=True)
    try:
        return {
            row[0]:(int(row[2].split(":")[1]),int(row[2].split(":")[2]),int(row[1]))
            for row in db.execute(
                "SELECT id,position,ayah_id FROM word "
                "WHERE position>0 AND id LIKE '%:W:%' AND mapping_state='SOURCE_ALIGNED'"
            )
        }
    finally:
        db.close()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--source",required=True,type=Path)
    parser.add_argument("--quran-db",required=True,type=Path)
    parser.add_argument("--source-lock",required=True,type=Path)
    args=parser.parse_args()

    source=args.source.resolve()
    manifest_path=source/"quran-audio"/"manifest.json"
    if not manifest_path.is_file():
        raise SystemExit("Missing quran-audio/manifest.json")
    manifest=json.loads(manifest_path.read_text(encoding="utf-8"))
    lock=json.loads(args.source_lock.read_text(encoding="utf-8"))
    if lock.get("schema")!=1:
        raise SystemExit("Unsupported Quran audio source lock schema")
    if manifest.get("source_lock_sha256")!=file_hash(args.source_lock):
        raise SystemExit("Quran audio pack was not built from the current reviewed source lock")

    if manifest.get("schema_version")!=2:
        raise SystemExit("Unsupported Quran audio manifest schema")
    if manifest.get("runtime_network_required") is not False:
        raise SystemExit("Quran audio pack must not require runtime network access")
    if manifest.get("coverage_complete") is not True:
        raise SystemExit("Incomplete Quran word-audio packs may not be bundled as active")
    if not args.quran_db.is_file():
        raise SystemExit("Canonical quran.sqlite is missing")
    actual_quran_hash=file_hash(args.quran_db)
    if manifest.get("canonical_quran_sqlite_sha256")!=actual_quran_hash:
        raise SystemExit("Quran audio pack targets a different canonical quran.sqlite")
    expected_url=f"https://huggingface.co/datasets/{lock.get('repo_id')}"
    locked_pairs={
        "source_version":str(lock.get("revision") or "").lower(),
        "source_url":expected_url,
        "license":str(lock.get("declared_license") or ""),
        "style":str(lock.get("style") or ""),
        "canonical_quran_sqlite_sha256":str(lock.get("canonical_quran_sqlite_sha256") or ""),
    }
    for key,expected_value in locked_pairs.items():
        if str(manifest.get(key) or "").lower()!=expected_value.lower():
            raise SystemExit(f"Quran audio manifest {key} differs from reviewed source lock")
    if int(manifest.get("word_count") or 0)!=int(lock.get("expected_word_count") or 0):
        raise SystemExit("Quran audio word count differs from reviewed source lock")
    if actual_quran_hash!=str(lock.get("canonical_quran_sqlite_sha256") or ""):
        raise SystemExit("Current quran.sqlite differs from reviewed audio source lock")

    for rel in manifest.get("license_files") or []:
        p=source/rel
        if not p.is_file() or p.stat().st_size<1:
            raise SystemExit(f"Missing license/provenance evidence: {rel}")
    if not manifest.get("license_files"):
        raise SystemExit("Quran audio pack must retain license/provenance evidence")

    index_rel=str(manifest.get("index_asset") or "")
    pack_root=str(manifest.get("pack_root") or "")
    if not index_rel.startswith("quran-audio/") or ".." in Path(index_rel).parts:
        raise SystemExit("Unsafe audio index path")
    if not pack_root.startswith("quran-audio/") or ".." in Path(pack_root).parts:
        raise SystemExit("Unsafe audio pack root")

    index_path=source/index_rel
    if not index_path.is_file():
        raise SystemExit("Quran audio index is missing")
    if file_hash(index_path)!=manifest.get("index_sha256"):
        raise SystemExit("Quran audio index hash mismatch")

    expected=canonical(args.quran_db)
    if int(manifest.get("word_count") or 0)!=len(expected):
        raise SystemExit("Manifest canonical word count mismatch")

    db=sqlite3.connect(f"file:{index_path}?mode=ro",uri=True)
    try:
        if db.execute("PRAGMA integrity_check").fetchone()[0]!="ok":
            raise SystemExit("Quran audio index integrity check failed")
        if db.execute("PRAGMA user_version").fetchone()[0]!=1:
            raise SystemExit("Quran audio index schema mismatch")
        rows=list(db.execute(
            "SELECT word_id,surah,ayah,position,byte_offset,byte_length "
            "FROM clip ORDER BY surah,byte_offset"
        ))
    finally:
        db.close()

    if len(rows)!=len(expected):
        raise SystemExit(f"Audio index coverage mismatch: {len(rows)} vs {len(expected)}")

    seen=set()
    grouped={}
    for word_id,surah,ayah,position,offset,length in rows:
        if word_id in seen:
            raise SystemExit(f"Duplicate audio word id: {word_id}")
        seen.add(word_id)
        canonical_coord=expected.get(word_id)
        if canonical_coord!=(int(surah),int(ayah),int(position)):
            raise SystemExit(f"Audio coordinate mismatch for {word_id}")
        if int(offset)<0 or int(length)<32:
            raise SystemExit(f"Invalid byte range for {word_id}")
        grouped.setdefault(int(surah),[]).append((int(offset),int(length),word_id))

    missing=set(expected)-seen
    extra=seen-set(expected)
    if missing or extra:
        raise SystemExit(f"Audio identity mismatch; missing={list(sorted(missing))[:10]}, extra={list(sorted(extra))[:10]}")

    declared=manifest.get("surah_packs")
    if not isinstance(declared,dict) or len(declared)!=114:
        raise SystemExit("Manifest must declare exactly 114 Surah packs")

    actual_pack_files=set()
    for surah in range(1,115):
        key=f"{surah:03d}"
        pack=source/pack_root/f"{key}.pack"
        if not pack.is_file():
            raise SystemExit(f"Missing Surah audio pack {key}")
        actual_pack_files.add(str(pack.relative_to(source)))
        meta=declared.get(key)
        if not isinstance(meta,dict):
            raise SystemExit(f"Missing Surah pack metadata {key}")
        if file_hash(pack)!=meta.get("sha256"):
            raise SystemExit(f"Surah {key} pack hash mismatch")
        if pack.stat().st_size!=int(meta.get("bytes") or -1):
            raise SystemExit(f"Surah {key} pack size mismatch")
        if pack.stat().st_size>MAX_SURAH_PACK_BYTES:
            raise SystemExit(f"Surah {key} pack exceeds ordinary-Git safety limit")

        clips=grouped.get(surah,[])
        if len(clips)!=int(meta.get("words") or -1):
            raise SystemExit(f"Surah {key} word count mismatch")
        cursor=0
        with pack.open("rb") as packed:
            for offset,length,word_id in clips:
                if offset!=cursor:
                    raise SystemExit(f"Non-contiguous audio range before {word_id}")
                packed.seek(offset)
                if packed.read(4)!=b"OggS":
                    raise SystemExit(f"Indexed clip does not begin with OggS: {word_id}")
                cursor+=length
        if cursor!=pack.stat().st_size:
            raise SystemExit(f"Surah {key} indexed bytes do not cover the whole pack")

    total_pack_bytes=sum((source/pack_root/f"{surah:03d}.pack").stat().st_size for surah in range(1,115))
    if total_pack_bytes>MAX_TOTAL_PACK_BYTES:
        raise SystemExit("Quran audio pack exceeds reviewed repository size budget")
    if int(manifest.get("total_pack_bytes") or -1)!=total_pack_bytes:
        raise SystemExit("Quran audio total size metadata mismatch")

    unexpected={
        str(p.relative_to(source))
        for p in (source/pack_root).rglob("*.pack")
        if p.is_file()
    }-actual_pack_files
    if unexpected:
        raise SystemExit("Unexpected Surah pack files: "+", ".join(sorted(unexpected)[:10]))

    print(json.dumps({
        "status":"PASS",
        "pack_id":manifest.get("pack_id"),
        "style":manifest.get("style"),
        "word_clips":len(rows),
        "surah_pack_files":114,
        "runtime_network_required":False,
    },ensure_ascii=False,indent=2))


if __name__=="__main__":
    main()
