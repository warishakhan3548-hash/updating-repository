from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
REMOTE_ACTION = re.compile(
    r"^\\s*(?:-\\s*)?uses:\\s*(?P<value>[^\\s#]+)",
    re.MULTILINE,
)
FULL_GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
DOCKER_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


class WorkflowSupplyChainTests(unittest.TestCase):
    def workflow_text(self, name: str) -> str:
        return (WORKFLOW_DIR / name).read_text(encoding="utf-8")

    def test_remote_actions_are_pinned_to_immutable_digests(self) -> None:
        failures: list[str] = []

        for workflow in sorted(WORKFLOW_DIR.glob("*.y*ml")):
            text = workflow.read_text(encoding="utf-8")
            for match in REMOTE_ACTION.finditer(text):
                value = match.group("value")
                line = text.count("\\n", 0, match.start()) + 1

                if value.startswith("./"):
                    continue

                if value.startswith("docker://"):
                    image = value.removeprefix("docker://")
                    _, separator, digest = image.rpartition("@")
                    if not separator or not DOCKER_DIGEST.fullmatch(digest):
                        failures.append(
                            f"{workflow.relative_to(ROOT)}:{line}: "
                            f"container action is not pinned by sha256 digest: {value}"
                        )
                    continue

                _, separator, ref = value.rpartition("@")
                if not separator or not FULL_GIT_SHA.fullmatch(ref):
                    failures.append(
                        f"{workflow.relative_to(ROOT)}:{line}: "
                        f"remote action/workflow must use a full 40-char commit SHA: {value}"
                    )

        self.assertEqual([], failures, "\\n".join(failures))

    def test_foundation_crypto_dependency_and_policy_are_pinned(self) -> None:
        requirements = (ROOT / "requirements-foundation.txt").read_text(
            encoding="utf-8"
        )
        pins = [
            line.strip()
            for line in requirements.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        self.assertEqual(["cryptography==50.0.1"], pins)

        foundation = self.workflow_text("foundation.yml")
        self.assertIn(
            "python -m pip install --disable-pip-version-check "
            "-r requirements-foundation.txt",
            foundation,
        )
        self.assertIn(
            "python tools/pack_signing.py policy/trusted_pack_keys.json",
            foundation,
        )

    def test_pack_builder_revalidates_the_committed_tree_before_push(self) -> None:
        text = self.workflow_text("build-quran-core-pack.yml")
        commit_index = text.index("git commit -m 'Build Quran canonical layer and core pack 1.1.0'")
        push_index = text.index("git push origin HEAD:main", commit_index)
        post_commit = text[commit_index:push_index]

        self.assertIn(
            "python -m pip install --disable-pip-version-check -r requirements-foundation.txt",
            text[:commit_index],
        )
        self.assertIn(
            "python tools/pack_signing.py policy/trusted_pack_keys.json",
            text[:commit_index],
        )
        self.assertIn("python tools/build_quran_canonical.py", text[:commit_index])
        self.assertIn("python tools/build_quran_core.py", text[:commit_index])
        self.assertIn("PACK_DIR=\'content-packs/quran-core/1.1.0\'", text[:commit_index])

        required = (
            "python tools/pack_signing.py policy/trusted_pack_keys.json",
            "python tools/vault_gate.py source-vault/registry.json",
            "python tools/pack_gate.py",
            "\"$PACK_DIR/manifest.json\"",
            "python tools/validate_schemas.py",
            "python -m unittest discover -s tests -v",
            "git status --porcelain",
        )
        for marker in required:
            with self.subTest(marker=marker):
                self.assertIn(marker, post_commit)


if __name__ == "__main__":
    unittest.main()
