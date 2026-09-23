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
import hashlib
import json
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
    manifest=json.loads((ACTIVE/"quran-audio"/"manifest.json").read_text(encoding="utf-8"))
    packs=sorted((ACTIVE/"quran-audio"/"packs").glob("*.pack"))
    expected_packs=int(manifest.get("pack_file_count") or 0)
    if expected_packs<1 or len(packs)!=expected_packs:
        raise SystemExit(f"Final chunk pack count mismatch: manifest={expected_packs}, files={len(packs)}")

    # Arm deletion safety only after the complete local payload has passed the network-free
    # verifier. From this point normal builds require this exact manifest and never fall back
    # to reacquisition or a website if the local audio payload is later removed.
    manifest_path=ACTIVE/"quran-audio"/"manifest.json"
    required_policy={
        "schema":1,
        "state":"required",
        "required_manifest_sha256":hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "required_pack_id":manifest["pack_id"],
        "on_missing":"FAIL_BUILD_NO_NETWORK_FALLBACK",
        "note":"Pinned automatically after a fully verified local Quran audio vendor import. Reacquisition is never part of a normal build.",
    }
    policy_tmp=POLICY.with_name(POLICY.name+".tmp")
    policy_tmp.write_text(json.dumps(required_policy,indent=2)+"\\n",encoding="utf-8")
    policy_tmp.replace(POLICY)

    run(sys.executable,ROOT/"tools/check_quran_audio_policy.py",
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
    print("Next: review and commit source-vault/quran-audio/active as ordinary Git files.")


if __name__=="__main__":
    main()
