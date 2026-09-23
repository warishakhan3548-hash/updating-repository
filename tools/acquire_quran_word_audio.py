#!/usr/bin/env python3
"""One-time acquisition helper for a pinned Hugging Face Quran word-audio snapshot.

IMPORTANT: this tool is never invoked by Gradle or Android runtime. Its only purpose is to make
an explicit, reviewable source-vault import. After the resulting active pack is committed (normally
through Git LFS), future builds use repository-local bytes only.
"""
import argparse
import re
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
    if revision is None:
        revision=str(HfApi().dataset_info(args.repo_id, revision="main").sha or "")
        print(f"Resolved {args.repo_id}@main -> {revision}", flush=True)
    if not re.fullmatch(r"[0-9a-fA-F]{40}", revision):
        raise SystemExit("Dataset revision did not resolve to an immutable 40-hex commit")

    with tempfile.TemporaryDirectory(prefix="aaris-quran-audio-") as temp:
        snapshot = Path(snapshot_download(
            repo_id=args.repo_id,
            repo_type="dataset",
            revision=revision,
            local_dir=Path(temp) / "snapshot",
            allow_patterns=[
                f"{args.style}/**",
                f"dataset/{args.style}/**",
                "README.md",
                "LICENSE",
                "LICENSE.*",
            ],
        ))
        candidates = [snapshot / args.style, snapshot / "dataset" / args.style]
        style_dir = next((path for path in candidates if path.is_dir()), None)
        if style_dir is None:
            raise SystemExit(f"Pinned dataset snapshot has no {args.style} word-audio directory")
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
