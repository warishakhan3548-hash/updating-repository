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

    def test_android_reader_ci_runs_lint_before_release_quality_claims(self) -> None:
        text = self.workflow_text("android-reader.yml")
        self.assertIn(":app:lintDebug", text)
        self.assertIn(":app:testDebugUnitTest", text)
        self.assertIn(":app:assembleDebug", text)

    def test_android_reader_ci_publishes_installable_debug_apk(self) -> None:
        text = self.workflow_text("android-reader.yml")
        self.assertIn(
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
            text,
        )
        self.assertIn("name: aaris-quran-debug", text)
        self.assertIn("app/build/outputs/apk/debug/app-debug.apk", text)
        self.assertIn("if-no-files-found: error", text)

    def test_foundation_ci_runs_independent_source_backup_gate(self) -> None:
        text = self.workflow_text("foundation.yml")
        self.assertIn(
            "python tools/source_backup_gate.py source-vault/registry.json",
            text,
        )

    def test_pack_builder_reruns_when_validation_tests_change(self) -> None:
        text = self.workflow_text("build-quran-core-pack.yml")
        self.assertIn("      - 'tests/**'\n", text)

    def test_pack_builder_installs_release_dependency_after_main_reset(self) -> None:
        text = self.workflow_text("build-quran-core-pack.yml")
        loop = text.index("for attempt in 1 2 3 4 5; do")
        reset = text.index("git reset --hard origin/main", loop)
        install = text.index(
            "python -m pip install --disable-pip-version-check "
            "-r requirements-ci.txt",
            reset,
        )
        complete = text.index("canonical_complete=false", install)
        self.assertLess(loop, reset)
        self.assertLess(reset, install)
        self.assertLess(install, complete)

    def test_existing_schema_v3_pack_path_runs_full_validation(self) -> None:
        text = self.workflow_text("build-quran-core-pack.yml")
        start = text.index(
            "Canonical Quran layer and Quran core 1.1.0 already exist"
        )
        end = text.index("exit 0", start)
        block = text[start:end]
        self.assertIn("python tools/vault_gate.py", block)
        self.assertIn("python tools/pack_gate.py", block)
        self.assertIn("python tools/validate_schemas.py", block)
        self.assertIn("python -m unittest discover -s tests -v", block)

    def test_pack_builder_revalidates_the_committed_tree_before_push(self) -> None:
        text = self.workflow_text("build-quran-core-pack.yml")
        commit_index = text.index("git commit -m 'Build Quran canonical layer and core pack 1.1.0'")
        push_index = text.index("git push origin HEAD:main", commit_index)
        post_commit = text[commit_index:push_index]

        self.assertIn("python tools/build_quran_canonical.py", text[:commit_index])
        self.assertIn("python tools/build_quran_core.py", text[:commit_index])
        self.assertIn("PACK_DIR=\'content-packs/quran-core/1.1.0\'", text[:commit_index])

        required = (
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
