#!/usr/bin/env python3
"""One-time acquisition helper for a pinned Hugging Face Quran word-audio snapshot.

IMPORTANT: this tool is never invoked by Gradle or Android runtime. Its only purpose is to make
an explicit, reviewable source-vault import. After the resulting active pack is committed as
ordinary repository files, future builds use repository-local bytes only.
"""
import argparse
import hashlib
import json
import re
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_LOCK = ROOT / "source-vault/quran-audio/source-lock.json"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "source-vault/quran-audio/active")
    parser.add_argument("--quran-db", type=Path, default=ROOT / "app/src/main/assets/quran.sqlite")
    parser.add_argument("--source-lock", type=Path, default=SOURCE_LOCK)
    args = parser.parse_args()

    lock=json.loads(args.source_lock.read_text(encoding="utf-8"))
    if lock.get("schema")!=1:
        raise SystemExit("Unsupported Quran audio source lock schema")
    repo_id=str(lock.get("repo_id") or "")
    revision=str(lock.get("revision") or "")
    style=str(lock.get("style") or "")
    extension=str(lock.get("extension") or "")
    license_tag=str(lock.get("declared_license_tag") or "")
    declared_license=str(lock.get("declared_license") or "")
    expected_count=int(lock.get("expected_word_count") or 0)
    expected_quran_hash=str(lock.get("canonical_quran_sqlite_sha256") or "")
    if not repo_id or not re.fullmatch(r"[0-9a-fA-F]{40}", revision):
        raise SystemExit("Invalid pinned Quran audio source lock")
    if style not in ("muallim","mujawwad") or extension!="opus":
        raise SystemExit("Unsupported pinned Quran audio style/format")
    if lock.get("canonical_policy")!="SOURCE_ALIGNED_W_ONLY":
        raise SystemExit("Unsupported Quran audio canonical policy")

    try:
        from huggingface_hub import HfApi, snapshot_download
    except ImportError:
        raise SystemExit("Install the one-time acquisition dependency: pip install huggingface_hub")

    info=HfApi().dataset_info(repo_id, revision=revision)
    if str(info.sha or "").lower()!=revision.lower():
        raise SystemExit("Hugging Face did not resolve the requested immutable dataset commit exactly")
    tags=set(info.tags or [])
    if license_tag not in tags:
        raise SystemExit("Pinned dataset license tag changed; review source rights before acquisition")
    if not args.quran_db.is_file():
        raise SystemExit("quran.sqlite is missing; run python3 tools/build_content.py first")
    actual_quran_hash=hashlib.sha256(args.quran_db.read_bytes()).hexdigest()
    if actual_quran_hash!=expected_quran_hash:
        raise SystemExit("Canonical quran.sqlite differs from the reviewed audio source lock")

    remote_files=HfApi().list_repo_files(repo_id, repo_type="dataset", revision=revision)
    prefixes=[f"dataset/{style}/", f"{style}/"]
    prefix=next((p for p in prefixes if any(name.startswith(p) and name.endswith(".opus") for name in remote_files)), None)
    if prefix is None:
        raise SystemExit(f"Pinned dataset snapshot has no {style} word-audio directory")

    db=sqlite3.connect(f"file:{args.quran_db.resolve()}?mode=ro", uri=True)
    try:
        canonical=list(db.execute(
            "SELECT ayah_id,position FROM word "
            "WHERE position>0 AND id LIKE '%:W:%' AND mapping_state='SOURCE_ALIGNED'"
        ))
    finally:
        db.close()

    if len(canonical)!=expected_count:
        raise SystemExit(f"Canonical safe word count changed: {len(canonical)} != reviewed {expected_count}")

    expected=set()
    for ayah_id,position in canonical:
        parts=ayah_id.split(":")
        if len(parts)!=3 or parts[0]!="Q":
            raise SystemExit(f"Invalid canonical ayah identity: {ayah_id}")
        surah,ayah=int(parts[1]),int(parts[2])
        expected.add(f"{prefix}{surah:03d}/{surah:03d}_{ayah:03d}_{int(position):03d}.{extension}")

    remote_opus={name for name in remote_files if name.startswith(prefix) and name.endswith("."+extension)}
    missing=sorted(expected-remote_opus)
    if missing:
        raise SystemExit("Pinned dataset is missing canonical SOURCE_ALIGNED audio: "+", ".join(missing[:20]))
    malformed=sorted(
        name for name in remote_opus
        if not re.fullmatch(re.escape(prefix)+r"\d{3}/\d{3}_\d{3}_\d{3}\.opus", name)
    )
    if malformed:
        raise SystemExit("Pinned dataset contains malformed word-audio names: "+", ".join(malformed[:20]))
    print(f"Remote coverage verified before download: {len(expected)} canonical words; prefix={prefix}", flush=True)

    with tempfile.TemporaryDirectory(prefix="aaris-quran-audio-") as temp:
        snapshot = Path(snapshot_download(
            repo_id=repo_id,
            repo_type="dataset",
            revision=revision,
            local_dir=Path(temp) / "snapshot",
            allow_patterns=[
                f"{prefix}**",
                "README.md",
                "LICENSE",
                "LICENSE.*",
            ],
        ))
        style_dir = snapshot / Path(prefix)
        if not style_dir.is_dir():
            raise SystemExit(f"Pinned dataset snapshot has no downloaded {style} word-audio directory")
        readme = snapshot / "README.md"
        if not readme.is_file():
            raise SystemExit("Pinned dataset snapshot has no README license/provenance evidence")
        evidence = Path(temp) / "UPSTREAM_EVIDENCE.txt"
        evidence_parts=[("README.md",readme.read_text(encoding="utf-8",errors="replace"))]
        for name in ("LICENSE","LICENSE.txt","LICENSE.md","LICENSE.apache-2.0"):
            candidate=snapshot/name
            if candidate.is_file():
                evidence_parts.append((name,candidate.read_text(encoding="utf-8",errors="replace")))
        evidence.write_text(
            "\n\n".join(f"===== {name} =====\n{text}" for name,text in evidence_parts)+"\n",
            encoding="utf-8"
        )

        subprocess.run([
            sys.executable,
            str(ROOT / "tools" / "prepare_quran_audio.py"),
            "--source", str(style_dir),
            "--quran-db", str(args.quran_db),
            "--output", str(args.output),
            "--license-evidence", str(evidence),
            "--source-name", "Quranic Word-By-Word Audio Data",
            "--source-version", revision.lower(),
            "--source-url", f"https://huggingface.co/datasets/{repo_id}",
            "--license", declared_license,
            "--style", style,
            "--extension", extension,
            "--source-lock", str(args.source_lock),
        ], check=True, cwd=ROOT)

    print("Pinned local audio pack is ready. Review it, then commit source-vault/quran-audio/active as ordinary Git files.")


if __name__ == "__main__":
    main()
