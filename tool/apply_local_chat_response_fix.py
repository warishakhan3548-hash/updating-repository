#!/usr/bin/env python3
"""Apply the verified local chat response fix; refuse divergent files."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zlib

BASE_COMMIT = 'dc7877d669f4285a452d44f6793eda8f44991330'
PATCH_SHA256 = 'f2983a5650f0ea461a76b233c6a02e78824923a9a5e41c12dd7012002d1be221'
MANIFEST = json.loads('{"docs/LOCAL_CHAT_RESPONSE_2026_09_15.md": {"after": "db737a1e74627937810bd11425ce823644c73384a7015b551a67d85d6ac0dce1", "before": null}, "lib/domain/local_ai_failure.dart": {"after": "8cd078925e976bcdbddeb624c4f21dedf0005565e07ddbdd7c9bc14058a477eb", "before": null}, "lib/services/local_ai_runtime.dart": {"after": "04783b2137436798935f0972d4c2c4d37a3986988510bf62c198dcee559f02c7", "before": "1cda014210b360a1cc5a16a496f23f6ab09db79f65f8a1dec53513718af66dd5"}, "lib/services/local_ai_service_io.dart": {"after": "d02a22803a3c08ca7a7e71d7aa17d64b99d67b40b18b74921865d77ac456986b", "before": "bcfc5cf972ce50f7cce10f136e94dcf61f85f6a79ed4dcfd4d17dda8c4282720"}, "lib/services/local_chat_turn.dart": {"after": "aa9f1a34ad4e394a7ee40f63dd0e357242cf47985cbcb6f0ec73a9b29bc0a032", "before": "07a8c298393876bd3b93ccb794655b7ba8857e8e57d399a2729951aeefc1af2f"}, "lib/ui/ai_screen.dart": {"after": "19004cd7bd8477bd1571a34dbc7d5a1e8c673a1bec133ab67eff35c0611a567a", "before": "06b0bd8367ea0c5f3b6e9c524aca5766d80c7dc23695cdb3a5f483fefd990c01"}, "tool/check_local_ai_error_drain.dart": {"after": "d7076e21787e1561f52fdb43483a1bc0b3a421f0a8ec9068b42c9874ce84b9f7", "before": "68a27f168f0f374aa79f148f0185a4f2051659c2234bc8067f4efe3925f96d1b"}, "tool/check_local_chat_response.dart": {"after": "c1be884442e5d0ae3b12670839306400adfc483340549d82ae3dc5e7afe1ff39", "before": null}}')
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
