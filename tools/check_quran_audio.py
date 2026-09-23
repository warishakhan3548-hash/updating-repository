#!/usr/bin/env python3
"""Network-free verifier for the compact APK-bundled Quran word-audio pack."""
import argparse
import hashlib
import json
import sqlite3
from pathlib import Path

MAX_PACK_BYTES = 32 * 1024 * 1024
MAX_TOTAL_PACK_BYTES = 650 * 1024 * 1024


def file_hash(path: Path) -> str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda:f.read(1024*1024),b""):
            h.update(chunk)
    return h.hexdigest()


def range_hash(handle,offset,length):
    h=hashlib.sha256()
    handle.seek(offset)
    remaining=length
    while remaining:
        chunk=handle.read(min(1024*1024,remaining))
        if not chunk:
            raise ValueError("Packed audio range ended early")
        h.update(chunk);remaining-=len(chunk)
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

    if manifest.get("schema_version")!=3:
        raise SystemExit("Unsupported Quran audio manifest schema")
    if manifest.get("pack_layout")!="CONTENT_ADDRESSED_CHUNKS_V1":
        raise SystemExit("Unsupported Quran audio pack layout")
    if int(manifest.get("pack_chunk_limit_bytes") or 0)!=MAX_PACK_BYTES:
        raise SystemExit("Quran audio pack chunk limit differs from reviewed layout")
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
        if db.execute("PRAGMA user_version").fetchone()[0]!=2:
            raise SystemExit("Quran audio index schema mismatch")
        if int(manifest.get("index_schema_version") or 0)!=2:
            raise SystemExit("Quran audio manifest/index schema mismatch")
        rows=list(db.execute(
            "SELECT word_id,surah,ayah,position,pack_id,byte_offset,byte_length,clip_sha256 "
            "FROM clip ORDER BY word_id"
        ))
    finally:
        db.close()

    if len(rows)!=len(expected):
        raise SystemExit(f"Audio index coverage mismatch: {len(rows)} vs {len(expected)}")

    seen=set()
    unique_ranges={}
    digest_locations={}
    for word_id,surah,ayah,position,pack_id,offset,length,digest in rows:
        if word_id in seen:
            raise SystemExit(f"Duplicate audio word id: {word_id}")
        seen.add(word_id)
        canonical_coord=expected.get(word_id)
        if canonical_coord!=(int(surah),int(ayah),int(position)):
            raise SystemExit(f"Audio coordinate mismatch for {word_id}")
        pack_id=int(pack_id);offset=int(offset);length=int(length);digest=str(digest or "")
        if pack_id<1 or offset<0 or length<32 or len(digest)!=64:
            raise SystemExit(f"Invalid packed audio reference for {word_id}")

        range_key=(pack_id,offset,length)
        previous_digest=unique_ranges.get(range_key)
        if previous_digest is not None and previous_digest!=digest:
            raise SystemExit(f"Same packed range has conflicting hashes: {word_id}")
        unique_ranges[range_key]=digest

        previous_range=digest_locations.get(digest)
        if previous_range is not None and previous_range!=range_key:
            raise SystemExit(f"Identical audio hash stored more than once instead of deduplicated: {word_id}")
        digest_locations[digest]=range_key

    missing=set(expected)-seen
    extra=seen-set(expected)
    if missing or extra:
        raise SystemExit(f"Audio identity mismatch; missing={list(sorted(missing))[:10]}, extra={list(sorted(extra))[:10]}")

    unique_count=len(unique_ranges)
    if unique_count!=int(manifest.get("unique_clip_count") or -1):
        raise SystemExit("Quran audio unique clip count mismatch")
    if len(rows)-unique_count!=int(manifest.get("deduplicated_reference_count") or -1):
        raise SystemExit("Quran audio deduplication count mismatch")

    declared=manifest.get("packs")
    if not isinstance(declared,dict) or not declared:
        raise SystemExit("Manifest must declare one or more chunk packs")
    if len(declared)!=int(manifest.get("pack_file_count") or -1):
        raise SystemExit("Quran audio pack file count mismatch")

    by_pack={}
    for (pack_id,offset,length),digest in unique_ranges.items():
        by_pack.setdefault(pack_id,[]).append((offset,length,digest))

    expected_pack_ids=list(range(1,len(declared)+1))
    actual_declared_ids=[]
    for key in declared:
        if not (isinstance(key,str) and len(key)==3 and key.isdigit()):
            raise SystemExit(f"Invalid Quran audio pack key: {key}")
        actual_declared_ids.append(int(key))
    if sorted(actual_declared_ids)!=expected_pack_ids:
        raise SystemExit("Quran audio pack IDs must be contiguous from 001")

    actual_pack_files=set()
    total_pack_bytes=0
    verified_unique=0
    for pack_id in expected_pack_ids:
        key=f"{pack_id:03d}"
        pack=source/pack_root/f"{key}.pack"
        if not pack.is_file():
            raise SystemExit(f"Missing Quran audio chunk pack {key}")
        actual_pack_files.add(str(pack.relative_to(source)))
        meta=declared.get(key)
        if not isinstance(meta,dict):
            raise SystemExit(f"Missing Quran audio pack metadata {key}")

        pack_bytes=pack.stat().st_size
        total_pack_bytes+=pack_bytes
        if pack_bytes<1 or pack_bytes>MAX_PACK_BYTES:
            raise SystemExit(f"Quran audio pack {key} violates chunk size limit")
        if file_hash(pack)!=meta.get("sha256"):
            raise SystemExit(f"Quran audio pack {key} hash mismatch")
        if pack_bytes!=int(meta.get("bytes") or -1):
            raise SystemExit(f"Quran audio pack {key} size mismatch")

        ranges=sorted(by_pack.get(pack_id,[]))
        if not ranges:
            raise SystemExit(f"Quran audio pack {key} has no indexed clips")
        if len(ranges)!=int(meta.get("unique_clips") or -1):
            raise SystemExit(f"Quran audio pack {key} unique clip count mismatch")

        cursor=0
        with pack.open("rb") as packed:
            for offset,length,digest in ranges:
                if offset!=cursor:
                    raise SystemExit(f"Non-contiguous unique audio range in pack {key} at {offset}")
                packed.seek(offset)
                if packed.read(4)!=b"OggS":
                    raise SystemExit(f"Indexed clip in pack {key} does not begin with OggS")
                try:
                    actual_digest=range_hash(packed,offset,length)
                except ValueError as exc:
                    raise SystemExit(str(exc))
                if actual_digest!=digest:
                    raise SystemExit(f"Packed word-audio range hash mismatch in pack {key}")
                cursor+=length;verified_unique+=1
        if cursor!=pack_bytes:
            raise SystemExit(f"Quran audio pack {key} contains unindexed trailing bytes")

    if verified_unique!=unique_count:
        raise SystemExit("Not every unique Quran audio clip was verified")
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
        raise SystemExit("Unexpected Quran audio pack files: "+", ".join(sorted(unexpected)[:10]))

    print(json.dumps({
        "status":"PASS",
        "pack_id":manifest.get("pack_id"),
        "style":manifest.get("style"),
        "word_references":len(rows),
        "unique_audio_clips":unique_count,
        "deduplicated_references":len(rows)-unique_count,
        "pack_files":len(declared),
        "total_pack_bytes":total_pack_bytes,
        "runtime_network_required":False,
    },ensure_ascii=False,indent=2))


if __name__=="__main__":
    main()
