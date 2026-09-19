#!/usr/bin/env python3
"""Keep medicine scan previews usable with a bounded, cancellable local AI review."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zlib

BASE_COMMIT = '487f50ab88d3b9c227eb0905e887aacf4a4995d0'
PATCH_SHA256 = 'c379bc7cf6513052c8087fe5aa25674b834bc254450c30e9f7b36842b5061975'
MANIFEST = json.loads('{"docs/SCAN_REVIEW_DEADLINE_2026_09_15.md": {"after": "ad5de61ae5489aeb0564d1a8a777f2d465c565c6106a080dab85e8ad1a918ae5", "before": null}, "lib/domain/local_scan_request.dart": {"after": "5ca1b564a7fd633659504cbf7e3efe602a3b2252f0d73db7140cdf37ab5dcd27", "before": null}, "lib/domain/medicine_intake.dart": {"after": "7fdee6fa5a15cbfa4b9471a3759254eecefdeded67c1d56568a514944f776445", "before": "1a445802324ce4fcc82d3cd6cddc0913b4e62a313d8068e83f252b0c44201b08"}, "lib/services/local_ai_service_io.dart": {"after": "6c30bacadbabc85f1b4e8ca7c3cd9ac08588ece3bd93754be3886d34eec988d6", "before": "23ff7ca9ddcd29657460dd368337e745fd5589d67b64a96b7c327b135fb2029c"}, "lib/services/local_ai_service_stub.dart": {"after": "f04c27902f96f149eded02c3a9bf05b0fd85065156d9454cac98c48f029a7c97", "before": "d663d87f587ce7f8e2e19b0086d64d6bdddd79166427a36590f157675895cd0e"}, "lib/services/local_brain_route_policy.dart": {"after": "de8f289aac5972d71ba1e74d4364052558b2afd0b5475fe3c7d4c51783944022", "before": "9a68b8af26e2e74834b51c4e2488582477997f2192a969e793e269617fe4d86a"}, "lib/services/medicine_intake_service.dart": {"after": "9b50ef95fb55a98201a5133ea2669ca73822eaf9be0d91c0c021f0a528fbc926", "before": "a97cb5fea8ac0b813b9614b88e421a9847dba6824270a60cbfe59768cf915d5b"}, "lib/services/medicine_review_pipeline.dart": {"after": "d11827a46166b7400625a903f37405ed496120b70b8d5cbd5b5dffe9c5ce68ba", "before": "ba62d3afd9d0a9cd28ad324dcc1d5a99f52c2fd40e37bc9951b5324375081f79"}, "lib/ui/medicine_intake_panel.dart": {"after": "c586154552fe2ca0c557ee0edd52a3e051aaaad2f2710878896bf28e167b9a69", "before": "36d482bf5149809eff48e9ef313fbd9aa54eb7402806ce9c415bdc520d2c85ae"}, "tool/check_scan_review_deadline.dart": {"after": "b9cbca7f3bd312f1f83ab60c62b02f9aa36b612d9fcb8c1ee0e092c3be84af10", "before": null}}')
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
