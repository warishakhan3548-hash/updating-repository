#!/usr/bin/env python3
"""Fail-closed policy gate for the repository-local Quran audio pack.

The real audio payload is optional only while release-policy.json is in pending_vendor_import.
After tools/complete_quran_audio_pack.py has fully verified a pinned pack, it switches the policy
to required and pins that pack's manifest SHA-256 + pack ID. From then on, normal builds fail if
the local pack is deleted, partially removed, replaced, or no longer matches the canonical Quran.
This script is network-free and never performs acquisition.
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

    source=args.source.resolve()
    payload=source/"quran-audio"
    manifest_path=payload/"manifest.json"

    if not manifest_path.is_file():
        if payload.exists():
            raise SystemExit("Partial Quran audio payload exists but manifest.json is missing")
        if state=="required":
            raise SystemExit("Required repository-local Quran audio pack is missing")
        print(json.dumps({
            "status":"PENDING_VENDOR_IMPORT",
            "audio_required":False,
            "runtime_network_fallback":False,
        },indent=2))
        return

    manifest_bytes=manifest_path.read_bytes()
    manifest=json.loads(manifest_bytes)
    if state=="required":
        expected_hash=str(policy.get("required_manifest_sha256") or "")
        expected_pack_id=str(policy.get("required_pack_id") or "")
        if len(expected_hash)!=64 or sha256(manifest_path)!=expected_hash:
            raise SystemExit("Required Quran audio manifest differs from pinned release policy")
        if not expected_pack_id or str(manifest.get("pack_id") or "")!=expected_pack_id:
            raise SystemExit("Required Quran audio pack ID differs from pinned release policy")

    subprocess.run([
        sys.executable,str(ROOT/"tools/check_quran_audio.py"),
        "--source",str(source),
        "--quran-db",str(args.quran_db),
        "--source-lock",str(args.source_lock),
    ],check=True,cwd=ROOT)

    print(json.dumps({
        "status":"PASS",
        "audio_required":state=="required",
        "pack_id":manifest.get("pack_id"),
        "manifest_sha256":sha256(manifest_path),
        "runtime_network_fallback":False,
    },indent=2))


if __name__=="__main__":
    main()
