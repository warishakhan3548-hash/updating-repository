import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "app" / "build.gradle.kts"
MANIFEST = ROOT / "app" / "src" / "main" / "AndroidManifest.xml"


class AndroidReaderTrustTests(unittest.TestCase):
    def test_release_delegates_to_authoritative_cryptographic_pack_gate(self):
        build = BUILD.read_text(encoding="utf-8")

        self.assertNotIn("releaseSignatureReady", build)
        self.assertNotIn("hasManifestString", build)
        self.assertIn('rootProject.file("tools/pack_gate.py")', build)
        self.assertIn(
            'rootProject.file("policy/trusted_pack_keys.json")',
            build,
        )
        self.assertIn(
            'tasks.matching { it.name == "preReleaseBuild" }',
            build,
        )

    def test_release_still_requires_approved_review_status_first(self):
        build = BUILD.read_text(encoding="utf-8")

        self.assertIn('check(packReviewStatus == "approved")', build)
        self.assertIn("not approved", build)

    def test_reader_bundles_current_canonical_candidate(self):
        build = BUILD.read_text(encoding="utf-8")
        self.assertIn(
            'rootProject.file("content-packs/quran-core/1.1.0")',
            build,
        )
        self.assertNotIn("content-packs/quran-core/1.0.4", build)

        manifest_path = (
            ROOT
            / "content-packs"
            / "quran-core"
            / "1.1.0"
            / "manifest.json"
        )
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(3, manifest["schema_version"])
        self.assertEqual("1.1.0", manifest["content_version"])
        self.assertEqual("candidate", manifest["review_status"])
        self.assertEqual("unsigned", manifest["signature"]["status"])
        self.assertEqual(6236, manifest["record_count"])
        self.assertEqual(
            "canonical/quran-core/1.0.0/ayahs.jsonl",
            manifest["canonical"]["artifact_path"],
        )

    def test_reader_has_no_direct_network_permission(self):
        manifest = MANIFEST.read_text(encoding="utf-8")

        self.assertNotIn("android.permission.INTERNET", manifest)
        self.assertNotIn("android.permission.ACCESS_NETWORK_STATE", manifest)


if __name__ == "__main__":
    unittest.main()
