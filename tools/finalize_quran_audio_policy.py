#!/usr/bin/env python3
"""Finalize an already acquired Quran audio pack for normal offline builds.

This tool is network-free. It verifies the complete local pack against the reviewed source lock and
canonical Quran, then atomically changes release-policy.json from pending_vendor_import to required,
pinning the exact manifest SHA-256 and pack ID. It never downloads or repairs missing bytes.

If a required policy already pins a different pack, finalization refuses to repin implicitly. A
source upgrade must first be an explicit reviewed policy/source-lock change.
"""
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
DEFAULT_SOURCE=ROOT/"source-vault/quran-audio/active"
DEFAULT_POLICY=ROOT/"source-vault/quran-audio/release-policy.json"
DEFAULT_DB=ROOT/"app/src/main/assets/quran.sqlite"
DEFAULT_LOCK=ROOT/"source-vault/quran-audio/source-lock.json"


def sha256(path: Path) -> str:
    h=hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b""):
            h.update(chunk)
    return h.hexdigest()


def run(*args):
    subprocess.run([str(x) for x in args],cwd=ROOT,check=True)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--source",type=Path,default=DEFAULT_SOURCE)
    parser.add_argument("--policy",type=Path,default=DEFAULT_POLICY)
    parser.add_argument("--quran-db",type=Path,default=DEFAULT_DB)
    parser.add_argument("--source-lock",type=Path,default=DEFAULT_LOCK)
    args=parser.parse_args()

    if not args.policy.is_file():
        raise SystemExit("Quran audio release policy is missing")
    policy=json.loads(args.policy.read_text(encoding="utf-8"))
    if policy.get("schema")!=1:
        raise SystemExit("Unsupported Quran audio release policy schema")
    state=str(policy.get("state") or "")
    if state not in ("pending_vendor_import","required"):
        raise SystemExit("Invalid Quran audio release policy state")

    manifest_path=args.source.resolve()/"quran-audio"/"manifest.json"
    if not manifest_path.is_file():
        raise SystemExit("Cannot finalize: complete local Quran audio manifest is missing")

    run(sys.executable,ROOT/"tools/check_quran_audio.py",
        "--source",args.source,
        "--quran-db",args.quran_db,
        "--source-lock",args.source_lock)

    manifest=json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest_hash=sha256(manifest_path)
    pack_id=str(manifest.get("pack_id") or "")
    if not pack_id:
        raise SystemExit("Cannot finalize Quran audio without a pack ID")

    if state=="required":
        if (str(policy.get("required_manifest_sha256") or "")!=manifest_hash or
            str(policy.get("required_pack_id") or "")!=pack_id):
            raise SystemExit(
                "Release policy already pins a different Quran audio pack; "
                "an upgrade requires an explicit reviewed reset to pending_vendor_import")
    else:
        required_policy={
            "schema":1,
            "state":"required",
            "required_manifest_sha256":manifest_hash,
            "required_pack_id":pack_id,
            "on_missing":"FAIL_BUILD_NO_NETWORK_FALLBACK",
            "note":"Pinned after a fully verified local Quran audio vendor import. Reacquisition is never part of a normal build.",
        }
        temporary=args.policy.with_name(args.policy.name+".tmp")
        temporary.write_text(json.dumps(required_policy,indent=2)+"\n",encoding="utf-8")
        temporary.replace(args.policy)

    run(sys.executable,ROOT/"tools/check_quran_audio_policy.py",
        "--source",args.source,
        "--policy",args.policy,
        "--quran-db",args.quran_db,
        "--source-lock",args.source_lock)

    print(json.dumps({
        "status":"FINALIZED",
        "pack_id":pack_id,
        "manifest_sha256":manifest_hash,
        "release_policy":"required",
        "runtime_network_fallback":False,
    },indent=2))


if __name__=="__main__":
    main()
