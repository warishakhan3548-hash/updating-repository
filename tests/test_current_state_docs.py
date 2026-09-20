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


    def test_qul_wbw_gloss_candidates_remain_unmirrored(self):
        registry = json.loads(
            (ROOT / "source-vault" / "registry.json").read_text(encoding="utf-8")
        )
        by_id = {item["source_id"]: item for item in registry["sources"]}

        candidates = {
            "quran-gloss.qul.english-wbw.resource-92":
                "https://qul.tarteel.ai/resources/translation/92",
            "quran-gloss.qul.hindi-wbw.resource-44":
                "https://qul.tarteel.ai/resources/translation/44",
        }
        for source_id, expected_url in candidates.items():
            source = by_id[source_id]
            self.assertEqual("quran-gloss", source["category"])
            self.assertEqual("awaiting-licence", source["status"])
            self.assertEqual(expected_url, source["original_url"])
            self.assertEqual("dataset-specific-unverified", source["licence_id"])
            self.assertIsNone(source["redistribution_allowed"])
            self.assertIsNone(source["commercial_use_allowed"])
            self.assertIsNone(source["modification_allowed"])
            self.assertIsNone(source["attribution_required"])
            self.assertIsNone(source["vault_artifact"])
            self.assertIsNone(source["licence_snapshot"])
            self.assertIsNone(source["provenance"])
            self.assertIsNone(source["sha256"])
            self.assertIsNone(source["byte_size"])
            self.assertEqual(
                "unresolved",
                source["release_requirements"][
                    "historical_snapshot_retention_status"
                ],
            )

        for manifest_path in (ROOT / "content-packs").glob("**/manifest.json"):
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertNotIn(
                manifest.get("source_id"),
                candidates,
                f"{manifest_path} must not consume unlicensed QUL WBW data",
            )


    def test_quranmorph_remains_awaiting_exact_authorized_artifact(self):
        registry = json.loads(
            (ROOT / "source-vault" / "registry.json").read_text(encoding="utf-8")
        )
        by_id = {item["source_id"]: item for item in registry["sources"]}
        source = by_id["morphology.quranmorph.2025"]

        self.assertEqual("awaiting-artifact", source["status"])
        self.assertEqual("CC-BY-4.0", source["licence_id"])
        self.assertTrue(source["redistribution_allowed"])
        self.assertTrue(source["commercial_use_allowed"])
        self.assertTrue(source["modification_allowed"])
        self.assertTrue(source["attribution_required"])
        self.assertEqual(
            {
                "latest_upstream_version_required": False,
                "version_check_url": "https://sina.birzeit.edu/quran/",
                "historical_snapshot_retention_status": "verified-allowed",
            },
            source["release_requirements"],
        )
        self.assertIsNone(source["vault_artifact"])
        self.assertIsNone(source["sha256"])
        self.assertIn("6,235", source["notes"])
        self.assertIn("6,236", source["notes"])


    def test_qac_commercial_use_is_explicitly_blocked(self):
        registry = json.loads(
            (ROOT / "source-vault" / "registry.json").read_text(encoding="utf-8")
        )
        by_id = {item["source_id"]: item for item in registry["sources"]}
        source = by_id["morphology.qac.v0.4"]

        self.assertEqual("awaiting-licence", source["status"])
        self.assertFalse(source["commercial_use_allowed"])
        self.assertIsNone(source["vault_artifact"])
        self.assertEqual(
            "unresolved",
            source["release_requirements"]["historical_snapshot_retention_status"],
        )

    def test_quran_foundation_rejection_records_retention_denial(self):
        registry = json.loads(
            (ROOT / "source-vault" / "registry.json").read_text(encoding="utf-8")
        )
        by_id = {item["source_id"]: item for item in registry["sources"]}
        source = by_id["quran.quran-foundation.api"]

        self.assertEqual("rejected", source["status"])
        self.assertFalse(source["redistribution_allowed"])
        self.assertEqual(
            "verified-not-allowed",
            source["release_requirements"]["historical_snapshot_retention_status"],
        )
        self.assertIsNone(source["vault_artifact"])

    def test_masaq_v5_stays_metadata_only_pending_rights_chain_review(self):
        registry = json.loads(
            (ROOT / "source-vault" / "registry.json").read_text(encoding="utf-8")
        )
        by_id = {item["source_id"]: item for item in registry["sources"]}
        source = by_id["morphology.masaq.v5"]

        self.assertEqual("5", source["version"])
        self.assertEqual("awaiting-licence", source["status"])
        self.assertIsNone(source["redistribution_allowed"])
        self.assertIsNone(source["commercial_use_allowed"])
        self.assertIsNone(source["modification_allowed"])
        self.assertTrue(source["attribution_required"])
        self.assertEqual(
            "unresolved",
            source["release_requirements"]["historical_snapshot_retention_status"],
        )
        self.assertIsNone(source["vault_artifact"])
        self.assertIsNone(source["licence_snapshot"])
        self.assertIsNone(source["provenance"])
        self.assertIsNone(source["sha256"])

    def test_eqtb_v1_stays_metadata_only_pending_rights_chain_review(self):
        registry = json.loads(
            (ROOT / "source-vault" / "registry.json").read_text(encoding="utf-8")
        )
        by_id = {item["source_id"]: item for item in registry["sources"]}
        source = by_id["morphology.eqtb.v1"]

        self.assertEqual("1", source["version"])
        self.assertEqual("awaiting-licence", source["status"])
        self.assertEqual(
            "https://data.mendeley.com/datasets/rk96pn66m4/1",
            source["original_url"],
        )
        self.assertIsNone(source["redistribution_allowed"])
        self.assertIsNone(source["commercial_use_allowed"])
        self.assertIsNone(source["modification_allowed"])
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
        self.assertIn("third-party", source["notes"].lower())
        self.assertIn("Quranic Arabic Corpus", source["notes"])

        for manifest_path in (ROOT / "content-packs").glob("**/manifest.json"):
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertNotEqual(
                source["source_id"],
                manifest.get("source_id"),
                f"{manifest_path} must not consume rights-unresolved EQTB data",
            )


    def test_tanzil_production_source_is_commercially_usable(self):
        registry = json.loads(
            (ROOT / "source-vault" / "registry.json").read_text(encoding="utf-8")
        )
        by_id = {item["source_id"]: item for item in registry["sources"]}
        source = by_id["quran.tanzil.uthmani.v1.1"]

        self.assertEqual("production-approved", source["status"])
        self.assertTrue(source["redistribution_allowed"])
        self.assertTrue(source["commercial_use_allowed"])
        self.assertEqual(
            {
                "latest_upstream_version_required": False,
                "version_check_url": "https://tanzil.net/updates/",
                "historical_snapshot_retention_status": "verified-allowed",
            },
            source["release_requirements"],
        )

    def test_quranenc_gloss_candidate_remains_outside_production(self):
        registry = json.loads(
            (ROOT / "source-vault" / "registry.json").read_text(encoding="utf-8")
        )
        by_id = {item["source_id"]: item for item in registry["sources"]}
        source = by_id["quran-gloss.quranenc.arabic-seraj.v1.0.0"]

        self.assertEqual("1.0.0", source["version"])
        self.assertEqual("awaiting-licence", source["status"])
        self.assertIsNone(source["redistribution_allowed"])
        self.assertFalse(source["modification_allowed"])
        self.assertTrue(source["attribution_required"])
        self.assertIn("historical", source["notes"])
        self.assertIn("reproducibility", source["notes"])
        self.assertIsNone(source["vault_artifact"])
        self.assertIsNone(source["licence_snapshot"])
        self.assertIsNone(source["provenance"])
        self.assertIsNone(source["sha256"])
        self.assertIsNone(source["byte_size"])
        self.assertEqual(
            "https://quranenc.com/en/home",
            source["release_requirements"]["version_check_url"],
        )
        self.assertEqual(
            "unresolved",
            source["release_requirements"]["historical_snapshot_retention_status"],
        )

        snapshot_path = (
            ROOT
            / "source-vault"
            / "quran-gloss"
            / "quranenc"
            / "arabic-seraj"
            / "1.0.0"
        )
        self.assertFalse(
            snapshot_path.exists(),
            "awaiting-licence QuranEnc bytes must not exist in the current Source Vault tree",
        )

        for manifest_path in (ROOT / "content-packs").glob("**/manifest.json"):
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertNotEqual(
                source["source_id"],
                manifest.get("source_id"),
                f"{manifest_path} must not consume unpreserved QuranEnc glosses",
            )

    def test_hadeethenc_observed_version_is_blocked_pending_archive_rights(self):
        registry = json.loads(
            (ROOT / "source-vault" / "registry.json").read_text(encoding="utf-8")
        )
        by_id = {item["source_id"]: item for item in registry["sources"]}
        source = by_id["hadith.hadeethenc.ar.current"]

        self.assertEqual("1.7.0-observed-2026-09-20", source["version"])
        self.assertEqual("awaiting-licence", source["status"])
        self.assertIsNone(source["redistribution_allowed"])
        self.assertIsNone(source["commercial_use_allowed"])
        self.assertEqual(
            {
                "latest_upstream_version_required": True,
                "version_check_url": "https://hadeethenc.com/en/check/ar/v1.7.0",
                "historical_snapshot_retention_status": "unresolved",
            },
            source["release_requirements"],
        )
        self.assertIsNone(source["vault_artifact"])
        self.assertIsNone(source["licence_snapshot"])
        self.assertIsNone(source["provenance"])
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
