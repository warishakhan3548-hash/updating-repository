from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "app" / "build.gradle.kts"
MANIFEST = ROOT / "app" / "src" / "main" / "AndroidManifest.xml"


class AndroidReaderTrustTests(unittest.TestCase):
    def test_reader_uses_current_schema_v3_candidate(self):
        build = BUILD.read_text(encoding="utf-8")
        self.assertIn('content-packs/quran-core/1.1.0', build)
        self.assertNotIn('content-packs/quran-core/1.0.4', build)

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

    def test_reader_has_no_direct_network_permission(self):
        manifest = MANIFEST.read_text(encoding="utf-8")

        self.assertNotIn("android.permission.INTERNET", manifest)
        self.assertNotIn("android.permission.ACCESS_NETWORK_STATE", manifest)


if __name__ == "__main__":
    unittest.main()
