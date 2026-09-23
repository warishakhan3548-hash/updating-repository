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
    packs=sorted((ACTIVE/"quran-audio/packs").glob("*.pack"))
    if len(packs)!=114:
        raise SystemExit(f"Expected 114 Surah pack files; found {len(packs)}")
    too_large=[p for p in packs if p.stat().st_size>=95*1024*1024]
    if too_large:
        raise SystemExit("Pack files too close to GitHub's per-file limit: "+", ".join(p.name for p in too_large))

    expected=int(lock.get("expected_word_count") or 0)
    if int(manifest.get("word_count") or 0)!=expected:
        raise SystemExit("Vendored pack word count differs from reviewed source lock")

    total=sum(p.stat().st_size for p in packs)
    print(json.dumps({
        "status":"READY_TO_COMMIT",
        "active_path":str(ACTIVE.relative_to(ROOT)),
        "word_clips":expected,
        "surah_packs":len(packs),
        "audio_bytes":total,
        "largest_pack_bytes":max(p.stat().st_size for p in packs),
        "source_revision":lock.get("revision"),
        "runtime_network_required":False,
        "next":"Review git status, then commit source-vault/quran-audio/active as ordinary Git files.",
    },ensure_ascii=False,indent=2))


if __name__=="__main__":
    main()
