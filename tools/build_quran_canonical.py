#!/usr/bin/env python3
"""Build the canonical Quran artifact from the pinned Source Vault snapshot."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.quran_canonical import DEFAULT_CANONICAL_DIR, build_canonical


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_CANONICAL_DIR,
        help="canonical output directory, relative to repository root",
    )
    args = parser.parse_args()
    artifact_path, manifest_path = build_canonical(args.root, args.output)
    print(f"Built {artifact_path}")
    print(f"Manifest {manifest_path}")


if __name__ == "__main__":
    main()
