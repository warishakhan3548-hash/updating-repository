#!/usr/bin/env python3
"""One-time end-to-end vendoring command for the reviewed Quran word-audio pack.

This is intentionally NOT part of Gradle. It is run only when a maintainer wants to acquire/update
the repository-local immutable audio vault. Once the generated active pack is committed, normal
Android builds and runtime are network-independent.
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
ACTIVE=ROOT/"source-vault/quran-audio/active"
LOCK=ROOT/"source-vault/quran-audio/source-lock.json"
QURAN_DB=ROOT/"app/src/main/assets/quran.sqlite"


def run(*args):
    print("+"," ".join(str(x) for x in args),flush=True)
    subprocess.run([str(x) for x in args],cwd=ROOT,check=True)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--replace",action="store_true",
                        help="Replace an existing verified active pack after acquisition succeeds.")
    parser.add_argument("--skip-disk-check",action="store_true")
    args=parser.parse_args()

    if not LOCK.is_file():
        raise SystemExit("Reviewed source-vault/quran-audio/source-lock.json is missing")
    lock=json.loads(LOCK.read_text(encoding="utf-8"))
    if lock.get("schema")!=1:
        raise SystemExit("Unsupported Quran audio source lock schema")

    if ACTIVE.exists() and not args.replace:
        raise SystemExit("Active Quran audio pack already exists; verify it or rerun with --replace")

    if not args.skip_disk_check:
        usage=shutil.disk_usage(ROOT)
        # Snapshot + staging pack + safety margin. This is acquisition-time only.
        required=2*1024*1024*1024
        if usage.free<required:
            raise SystemExit(f"At least 2 GiB free disk is required for one-time audio vendoring; free={usage.free}")

    run(sys.executable,"tools/build_content.py")
    run(sys.executable,"tools/check_offline_contract.py")
    run(sys.executable,"tools/acquire_quran_word_audio.py",
        "--quran-db",QURAN_DB,
        "--source-lock",LOCK,
        "--output",ACTIVE)
    run(sys.executable,"tools/check_quran_audio.py",
        "--source",ACTIVE,
        "--quran-db",QURAN_DB,
        "--source-lock",LOCK)

    manifest=json.loads((ACTIVE/"quran-audio/manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schema_version")!=3 or manifest.get("pack_layout")!="CONTENT_ADDRESSED_CHUNKS_V1":
        raise SystemExit("Vendored Quran audio pack does not use the reviewed schema-v3 chunk layout")

    declared=manifest.get("packs")
    pack_count=int(manifest.get("pack_file_count") or 0)
    if not isinstance(declared,dict) or pack_count<1 or len(declared)!=pack_count:
        raise SystemExit("Vendored Quran audio manifest has an invalid chunk-pack declaration")

    expected_names=[f"{pack_id:03d}.pack" for pack_id in range(1,pack_count+1)]
    packs=sorted((ACTIVE/"quran-audio/packs").glob("*.pack"))
    actual_names=[p.name for p in packs]
    if actual_names!=expected_names:
        raise SystemExit(
            f"Chunk-pack files differ from manifest layout: expected={expected_names}, actual={actual_names}"
        )

    chunk_limit=int(manifest.get("pack_chunk_limit_bytes") or 0)
    if chunk_limit!=32*1024*1024:
        raise SystemExit("Vendored Quran audio chunk limit differs from the reviewed layout")
    too_large=[p for p in packs if p.stat().st_size<1 or p.stat().st_size>chunk_limit]
    if too_large:
        raise SystemExit("Invalid Quran audio chunk size: "+", ".join(p.name for p in too_large))

    expected=int(lock.get("expected_word_count") or 0)
    if int(manifest.get("word_count") or 0)!=expected:
        raise SystemExit("Vendored pack word count differs from reviewed source lock")
    unique=int(manifest.get("unique_clip_count") or 0)
    deduplicated=int(manifest.get("deduplicated_reference_count") or -1)
    if unique<1 or unique+deduplicated!=expected:
        raise SystemExit("Vendored pack deduplication counts are inconsistent")

    total=sum(p.stat().st_size for p in packs)
    if total!=int(manifest.get("total_pack_bytes") or -1):
        raise SystemExit("Vendored pack byte total differs from its verified manifest")
    if total>650*1024*1024:
        raise SystemExit("Vendored Quran audio exceeds the reviewed ordinary-Git size budget")

    print(json.dumps({
        "status":"READY_TO_COMMIT",
        "active_path":str(ACTIVE.relative_to(ROOT)),
        "word_references":expected,
        "unique_audio_clips":unique,
        "deduplicated_references":deduplicated,
        "chunk_packs":pack_count,
        "audio_bytes":total,
        "largest_pack_bytes":max(p.stat().st_size for p in packs),
        "source_revision":lock.get("revision"),
        "runtime_network_required":False,
        "next":"Review git status, then commit source-vault/quran-audio/active as ordinary Git files.",
    },ensure_ascii=False,indent=2))


if __name__=="__main__":
    main()
