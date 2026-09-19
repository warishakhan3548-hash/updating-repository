#!/usr/bin/env python3
"""Keep optional extraction-probe failures from blocking load-tested local chat."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zlib

BASE_COMMIT = '867d6aa72a3f73ebda5c2e7c187ce5991b05b5d9'
PATCH_SHA256 = '029121f8cddf449217fc155923b2be3adbcf076bc474e1e6bd86c7bb683ec389'
MANIFEST = json.loads('{"docs/LOCAL_CHAT_RESPONSE_2026_09_15.md": {"after": "dad9ea18c32257ff2534793378e6e7101d656bb6697bdf99a5089e4c6e2a1359", "before": "db737a1e74627937810bd11425ce823644c73384a7015b551a67d85d6ac0dce1"}, "lib/services/local_ai_service_io.dart": {"after": "23ff7ca9ddcd29657460dd368337e745fd5589d67b64a96b7c327b135fb2029c", "before": "d02a22803a3c08ca7a7e71d7aa17d64b99d67b40b18b74921865d77ac456986b"}, "lib/services/local_scan_probe.dart": {"after": "c31b25569317db974ce0a1586a1e4c4b09b9aa0db58012816677d7ad62b98b12", "before": null}, "tool/check_local_scan_probe.dart": {"after": "ebe25400fbfdb5bc0b074623285cd1d88a9f6a32fa7d5ad1c3b139f0dcd0c8a3", "before": null}}')
PATCH_DATA = (
    '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'
)

def run_git(repo, *args, data=None):
    result = subprocess.run(["git", "-C", str(repo), *args], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", "replace").strip())
    return result.stdout

def digest(repo, relative):
    path = repo / relative
    if path.is_symlink() or any(parent.is_symlink() for parent in path.parents
                                if parent != repo and repo in parent.parents):
        raise RuntimeError("Refusing a symlink target: " + relative)
    if not path.resolve().is_relative_to(repo):
        raise RuntimeError("Target escapes repository: " + relative)
    if not path.exists():
        return None
    if not path.is_file():
        raise RuntimeError("Target is not a regular file: " + relative)
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--check", action="store_true", help="Verify without writing")
    args = parser.parse_args()
    repo = args.repo.expanduser().resolve()
    top = Path(run_git(repo, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    if top != repo:
        raise RuntimeError("--repo must name the repository root: " + str(top))
    patch = zlib.decompress(base64.b64decode(PATCH_DATA))
    if hashlib.sha256(patch).hexdigest() != PATCH_SHA256:
        raise RuntimeError("Embedded patch integrity check failed.")
    current = {name: digest(repo, name) for name in MANIFEST}
    if all(current[name] == facts["after"] for name, facts in MANIFEST.items()):
        print("Upgrade already applied. No files changed.")
        return
    changed = [name for name, facts in MANIFEST.items()
               if current[name] != facts["before"]]
    if changed:
        raise RuntimeError("Affected files differ from the expected source. Nothing changed.\n"
                           + "\n".join(changed))
    # Git verifies all hunks before applying; never use --reject or force/reset.
    run_git(repo, "apply", "--check", "--whitespace=error", "-", data=patch)
    if args.check:
        print(f"Ready: {len(MANIFEST)} files verified. No files changed.")
        return
    run_git(repo, "apply", "--whitespace=error", "-", data=patch)
    wrong = [name for name, facts in MANIFEST.items()
             if digest(repo, name) != facts["after"]]
    if wrong:
        raise RuntimeError("Post-apply verification failed: " + ", ".join(wrong))
    print(f"Applied and verified {len(MANIFEST)} files. No commit, push, build or CI started.")

if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, zlib.error) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
