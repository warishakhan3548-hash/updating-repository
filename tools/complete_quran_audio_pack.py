#!/usr/bin/env python3
"""One-command maintainer workflow for preparing the repository-local Quran word-audio pack.

This is deliberately NOT a Gradle task. It is a one-time acquisition/finalization command:
1) rebuild canonical Quran content from vendored sources,
2) verify the reviewed source lock matches that exact Quran SQLite,
3) acquire the immutable pinned upstream snapshot,
4) compact SOURCE_ALIGNED word clips into 114 local Surah pack files,
5) run the fully network-free pack verifier.

After this succeeds, commit source-vault/quran-audio/active to the repository. Future Android
builds/runtime use only those committed bytes and never invoke this script or the network.
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
LOCK=ROOT/"source-vault/quran-audio/source-lock.json"
DB=ROOT/"app/src/main/assets/quran.sqlite"
ACTIVE=ROOT/"source-vault/quran-audio/active"


def run(*args):
    print("+"," ".join(str(x) for x in args),flush=True)
    subprocess.run([str(x) for x in args],cwd=ROOT,check=True)


def main():
    if not LOCK.is_file():
        raise SystemExit("Missing reviewed Quran audio source lock")

    run(sys.executable,ROOT/"tools/build_content.py")

    try:
        import huggingface_hub  # noqa: F401
    except ImportError:
        raise SystemExit(
            "One-time acquisition dependency is missing. Install it in the maintainer environment "
            "with: python3 -m pip install huggingface_hub"
        )

    run(sys.executable,ROOT/"tools/acquire_quran_word_audio.py",
        "--quran-db",DB,
        "--source-lock",LOCK,
        "--output",ACTIVE)

    run(sys.executable,ROOT/"tools/check_quran_audio.py",
        "--source",ACTIVE,
        "--quran-db",DB,
        "--source-lock",LOCK)

    lock=json.loads(LOCK.read_text(encoding="utf-8"))
    packs=sorted((ACTIVE/"quran-audio"/"packs").glob("*.pack"))
    if len(packs)!=114:
        raise SystemExit(f"Expected 114 final Surah pack files, found {len(packs)}")

    print()
    print("Quran word-audio pack is locally complete and verified.")
    print(f"Canonical safe words: {lock['expected_word_count']}")
    print("Surah pack files: 114")
    print("Runtime/build network dependency: none after these files are committed")
    print("Next: review and commit source-vault/quran-audio/active as ordinary Git files.")


if __name__=="__main__":
    main()
