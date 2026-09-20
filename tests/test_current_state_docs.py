from __future__ import annotations

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def _semver(path: Path) -> tuple[int, int, int] | None:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", path.name)
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


class CurrentStateDocumentationTests(unittest.TestCase):
    def _latest_quran_manifest(self) -> dict:
        base = ROOT / "content-packs" / "quran-core"
        versions = [
            (version, path)
            for path in base.iterdir()
            if path.is_dir() and (version := _semver(path)) is not None
        ]
        self.assertTrue(versions, "no quran-core content-pack versions found")
        _, latest = max(versions)
        return json.loads((latest / "manifest.json").read_text(encoding="utf-8"))

    def test_human_status_tracks_latest_quran_candidate(self):
        manifest = self._latest_quran_manifest()
        version = manifest["content_version"]
        built_sha256 = manifest["built_sha256"]

        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        progress = (ROOT / "docs" / "PROGRESS.md").read_text(encoding="utf-8")

        self.assertIn(f"quran-core {version}", readme)
        self.assertIn(f"content version: `{version}`", progress)
        self.assertIn(built_sha256, progress)

    def test_qul_word_level_candidates_remain_fail_closed(self):
        registry = json.loads(
            (ROOT / "source-vault" / "registry.json").read_text(encoding="utf-8")
        )
        by_id = {item["source_id"]: item for item in registry["sources"]}

        for source_id in (
            "morphology.qul.word-lemma.resource-75",
            "morphology.qul.word-root.resource-76",
        ):
            source = by_id[source_id]
            self.assertEqual("awaiting-licence", source["status"])
            self.assertIsNone(source["vault_artifact"])
            self.assertIsNone(source["sha256"])
            self.assertIsNot(source["redistribution_allowed"], True)


if __name__ == "__main__":
    unittest.main()
