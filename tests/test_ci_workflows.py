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

    def test_pack_builder_revalidates_the_committed_tree_before_push(self) -> None:
        text = self.workflow_text("build-quran-core-pack.yml")
        commit_index = text.index("git commit -m 'Build Quran core content pack 1.0.4'")
        push_index = text.index("git push origin HEAD:main", commit_index)
        post_commit = text[commit_index:push_index]

        required = (
            "python tools/vault_gate.py source-vault/registry.json",
            "python tools/pack_gate.py",
            "content-packs/quran-core/1.0.4/manifest.json",
            "python tools/validate_schemas.py",
            "python -m unittest discover -s tests -v",
            "git status --porcelain",
        )
        for marker in required:
            with self.subTest(marker=marker):
                self.assertIn(marker, post_commit)


    def test_python_ci_installs_pinned_trust_dependency(self) -> None:
        requirement = (ROOT / "requirements-trust.txt").read_text(encoding="utf-8").strip()
        self.assertRegex(requirement, r"^cryptography==[0-9]+(?:\\.[0-9]+){2}$")

        for workflow_name in ("foundation.yml", "build-quran-core-pack.yml"):
            with self.subTest(workflow=workflow_name):
                text = self.workflow_text(workflow_name)
                self.assertIn(
                    "python -m pip install -r requirements-trust.txt",
                    text,
                )



if __name__ == "__main__":
    unittest.main()
