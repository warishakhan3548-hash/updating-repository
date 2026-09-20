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
        self.assertIn("canonical", manifest)

    def test_release_build_embeds_signed_sequence_for_runtime_rollback_state(self):
        build = BUILD.read_text(encoding="utf-8")

        self.assertIn('manifestLong("release_sequence") ?: 0L', build)
        self.assertIn(
            'buildConfigField("long", "QURAN_PACK_RELEASE_SEQUENCE"',
            build,
        )

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
        state_store = (
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

        self.assertIn("QURAN_PACK_RELEASE_SEQUENCE", repository)
        self.assertIn("PackActivationStateStore", repository)
        self.assertIn("context.noBackupFilesDir", state_store)
        self.assertIn("AtomicFile", state_store)

    def test_reader_has_no_direct_network_permission(self):
        manifest = MANIFEST.read_text(encoding="utf-8")

        self.assertNotIn("android.permission.INTERNET", manifest)
        self.assertNotIn("android.permission.ACCESS_NETWORK_STATE", manifest)


if __name__ == "__main__":
    unittest.main()