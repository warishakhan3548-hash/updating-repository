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


    def test_quranmorph_remains_awaiting_exact_authorized_artifact(self):
        registry = json.loads(
            (ROOT / "source-vault" / "registry.json").read_text(encoding="utf-8")
        )
        by_id = {item["source_id"]: item for item in registry["sources"]}
        source = by_id["morphology.quranmorph.2025"]

        self.assertEqual("awaiting-artifact", source["status"])
        self.assertEqual("CC-BY-4.0", source["licence_id"])
        self.assertTrue(source["redistribution_allowed"])
        self.assertTrue(source["modification_allowed"])
        self.assertTrue(source["attribution_required"])
        self.assertIsNone(source["vault_artifact"])
        self.assertIsNone(source["sha256"])
        self.assertIn("6,235", source["notes"])
        self.assertIn("6,236", source["notes"])


    def test_quranenc_gloss_candidate_remains_outside_production(self):
        registry = json.loads(
            (ROOT / "source-vault" / "registry.json").read_text(encoding="utf-8")
        )
        by_id = {item["source_id"]: item for item in registry["sources"]}
        source = by_id["quran-gloss.quranenc.arabic-seraj.v1.0.0"]

        self.assertEqual("1.0.0", source["version"])
        self.assertEqual("awaiting-licence", source["status"])
        self.assertTrue(source["redistribution_allowed"])
        self.assertFalse(source["modification_allowed"])
        self.assertTrue(source["attribution_required"])
        self.assertEqual(
            "unresolved",
            source["release_requirements"]["historical_snapshot_retention_status"],
        )
        self.assertIsNone(source["vault_artifact"])
        self.assertIsNone(source["licence_snapshot"])
        self.assertIsNone(source["provenance"])
        self.assertIsNone(source["sha256"])
        self.assertIsNone(source["byte_size"])

        for manifest_path in (ROOT / "content-packs").glob("**/manifest.json"):
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertNotEqual(
                source["source_id"],
                manifest.get("source_id"),
                f"{manifest_path} must not consume unpreserved QuranEnc glosses",
            )

    def test_hadeethenc_observed_version_is_not_promoted(self):
        registry = json.loads(
            (ROOT / "source-vault" / "registry.json").read_text(encoding="utf-8")
        )
        by_id = {item["source_id"]: item for item in registry["sources"]}
        source = by_id["hadith.hadeethenc.ar.current"]

        self.assertEqual("1.7.0-observed-2026-09-20", source["version"])
        self.assertEqual("research-candidate", source["status"])
        self.assertIsNone(source["vault_artifact"])
        self.assertIsNone(source["sha256"])


    def test_manifest_spec_tracks_signature_domain(self):
        spec = (ROOT / "docs" / "PACK_MANIFEST_SPEC.md").read_text(encoding="utf-8")
        signing = (ROOT / "docs" / "CONTENT_SIGNING.md").read_text(encoding="utf-8")
        domain = "AARIS-CONTENT-PACK-SIGNATURE-V1\\\\n"

        self.assertIn(domain, spec)
        self.assertIn(domain, signing)


    def test_android_pack_activation_is_process_serialized(self):
        repository = (
            ROOT
            / "app"
            / "src"
            / "main"
            / "java"
            / "com"
            / "aaris"
            / "quran"
            / "data"
            / "PackagedQuranRepository.kt"
        ).read_text(encoding="utf-8")
        store = (
            ROOT
            / "app"
            / "src"
            / "main"
            / "java"
            / "com"
            / "aaris"
            / "quran"
            / "data"
            / "PackActivationStateStore.kt"
        ).read_text(encoding="utf-8")
        secure_updates = (ROOT / "docs" / "SECURE_UPDATES.md").read_text(
            encoding="utf-8"
        )

        self.assertIn("PACK_ACTIVATION_PROCESS_LOCK", store)
        self.assertIn(
            "synchronized(PACK_ACTIVATION_PROCESS_LOCK)",
            store,
        )
        self.assertIn(
            "synchronized(PACK_ACTIVATION_PROCESS_LOCK)",
            repository,
        )
        self.assertIn("no locking semantics", secure_updates)
        self.assertIn("process-wide lock", secure_updates)


if __name__ == "__main__":
    unittest.main()
