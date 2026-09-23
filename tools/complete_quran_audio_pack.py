#!/usr/bin/env python3
"""One-command maintainer workflow for preparing the repository-local Quran word-audio pack.

This is deliberately NOT a Gradle task. It is a one-time acquisition/finalization command:
1) rebuild canonical Quran content from vendored sources,
2) verify the reviewed source lock matches that exact Quran SQLite,
3) acquire the immutable pinned upstream snapshot,
4) deduplicate SOURCE_ALIGNED word clips into small local content-addressed chunk packs,
5) run the fully network-free pack verifier.

After this succeeds, commit source-vault/quran-audio/active to the repository. Future Android
builds/runtime use only those committed bytes and never invoke this script or the network.
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
LOCK=ROOT/"source-vault/quran-audio/source-lock.json"
DB=ROOT/"app/src/main/assets/quran.sqlite"
ACTIVE=ROOT/"source-vault/quran-audio/active"
POLICY=ROOT/"source-vault/quran-audio/release-policy.json"


def run(*args):
    print("+"," ".join(str(x) for x in args),flush=True)
    subprocess.run([str(x) for x in args],cwd=ROOT,check=True)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--replace",action="store_true",
                        help="Deliberately replace an existing verified active audio pack.")
    parser.add_argument("--skip-disk-check",action="store_true",
                        help="Skip the conservative one-time 2 GiB free-space preflight.")
    args=parser.parse_args()

    if not LOCK.is_file():
        raise SystemExit("Missing reviewed Quran audio source lock")
    if ACTIVE.exists() and not args.replace:
        raise SystemExit(
            "Active Quran audio already exists. Verify/use it as-is, or rerun explicitly with --replace."
        )
    if not args.skip_disk_check:
        free=shutil.disk_usage(ROOT).free
        required=2*1024*1024*1024
        if free<required:
            raise SystemExit(
                f"At least 2 GiB free disk is required for one-time Quran audio acquisition; free={free}"
            )

    # Prove the normal Android/build path is still network-independent before this explicit,
    # one-time network acquisition is allowed to begin.
    run(sys.executable,ROOT/"tools/check_offline_contract.py")
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
    manifest=json.loads((ACTIVE/"quran-audio"/"manifest.json").read_text(encoding="utf-8"))
    packs=sorted((ACTIVE/"quran-audio"/"packs").glob("*.pack"))
    expected_packs=int(manifest.get("pack_file_count") or 0)
    if expected_packs<1 or len(packs)!=expected_packs:
        raise SystemExit(f"Final chunk pack count mismatch: manifest={expected_packs}, files={len(packs)}")

    # Finalization is a separate network-free step shared by the one-command and manual flows.
    # It re-verifies the local pack, atomically arms the release policy, and pins the exact
    # manifest hash + pack ID. It never downloads or repairs content.
    run(sys.executable,ROOT/"tools/finalize_quran_audio_policy.py",
        "--source",ACTIVE,
        "--policy",POLICY,
        "--quran-db",DB,
        "--source-lock",LOCK)

    print()
    print("Quran word-audio pack is locally complete and verified.")
    print(f"Canonical safe words: {lock['expected_word_count']}")
    print(f"Unique audio clips: {manifest['unique_clip_count']}")
    print(f"Deduplicated references: {manifest['deduplicated_reference_count']}")
    print(f"Chunk pack files: {expected_packs}")
    print(f"Packed audio bytes: {manifest['total_pack_bytes']}")
    print("Runtime/build network dependency: none after these files are committed")
    print("Release policy: REQUIRED and pinned to this exact verified manifest")
    print("Next: review and commit source-vault/quran-audio/active plus source-vault/quran-audio/release-policy.json.")


if __name__=="__main__":
    main()
