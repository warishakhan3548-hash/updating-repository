#!/usr/bin/env python3
"""One-time acquisition helper for a pinned Hugging Face Quran word-audio snapshot.

IMPORTANT: this tool is never invoked by Gradle or Android runtime. Its only purpose is to make
an explicit, reviewable source-vault import. After the resulting active pack is committed (normally
through Git LFS), future builds use repository-local bytes only.
"""
import argparse
import re
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPO = "zaibihassan/Quranic-Word-By-Word-Audio-Data"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision", default=None,
                        help="Optional pinned 40-hex Hugging Face dataset commit. If omitted, main is resolved once to an immutable commit before download.")
    parser.add_argument("--repo-id", default=DEFAULT_REPO)
    parser.add_argument("--style", choices=("muallim", "mujawwad"), default="muallim")
    parser.add_argument("--output", type=Path, default=ROOT / "source-vault/quran-audio/active")
    parser.add_argument("--quran-db", type=Path, default=ROOT / "app/src/main/assets/quran.sqlite")
    args = parser.parse_args()

    try:
        from huggingface_hub import HfApi, snapshot_download
    except ImportError:
        raise SystemExit("Install the one-time acquisition dependency: pip install huggingface_hub")

    revision=args.revision
    info=HfApi().dataset_info(args.repo_id, revision=revision or "main")
    if revision is None:
        revision=str(info.sha or "")
        print(f"Resolved {args.repo_id}@main -> {revision}", flush=True)
    if not re.fullmatch(r"[0-9a-fA-F]{40}", revision):
        raise SystemExit("Dataset revision did not resolve to an immutable 40-hex commit")

    tags=set(info.tags or [])
    if "license:apache-2.0" not in tags:
        raise SystemExit("Pinned dataset no longer declares Apache-2.0; review source rights before acquisition")
    if not args.quran_db.is_file():
        raise SystemExit("quran.sqlite is missing; run python3 tools/build_content.py first")

    remote_files=HfApi().list_repo_files(args.repo_id, repo_type="dataset", revision=revision)
    prefixes=[f"dataset/{args.style}/", f"{args.style}/"]
    prefix=next((p for p in prefixes if any(name.startswith(p) and name.endswith(".opus") for name in remote_files)), None)
    if prefix is None:
        raise SystemExit(f"Pinned dataset snapshot has no {args.style} word-audio directory")

    db=sqlite3.connect(f"file:{args.quran_db.resolve()}?mode=ro", uri=True)
    try:
        canonical=list(db.execute(
            "SELECT ayah_id,position FROM word "
            "WHERE position>0 AND id LIKE '%:W:%' AND mapping_state='SOURCE_ALIGNED'"
        ))
    finally:
        db.close()

    expected=set()
    for ayah_id,position in canonical:
        parts=ayah_id.split(":")
        if len(parts)!=3 or parts[0]!="Q":
            raise SystemExit(f"Invalid canonical ayah identity: {ayah_id}")
        surah,ayah=int(parts[1]),int(parts[2])
        expected.add(f"{prefix}{surah:03d}/{surah:03d}_{ayah:03d}_{int(position):03d}.opus")

    remote_opus={name for name in remote_files if name.startswith(prefix) and name.endswith(".opus")}
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
            repo_id=args.repo_id,
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
            raise SystemExit(f"Pinned dataset snapshot has no downloaded {args.style} word-audio directory")
        evidence = snapshot / "README.md"
        if not evidence.is_file():
            raise SystemExit("Pinned dataset snapshot has no README license/provenance evidence")

        subprocess.run([
            sys.executable,
            str(ROOT / "tools" / "prepare_quran_audio.py"),
            "--source", str(style_dir),
            "--quran-db", str(args.quran_db),
            "--output", str(args.output),
            "--license-evidence", str(evidence),
            "--source-name", "Quranic Word-By-Word Audio Data",
            "--source-version", revision.lower(),
            "--source-url", f"https://huggingface.co/datasets/{args.repo_id}",
            "--license", "Apache-2.0",
            "--style", args.style,
            "--extension", "opus",
        ], check=True, cwd=ROOT)

    print("Pinned local audio pack is ready. Review it, then commit source-vault/quran-audio/active via Git LFS.")


if __name__ == "__main__":
    main()
