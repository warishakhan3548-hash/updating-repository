from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "app" / "build.gradle.kts"
MANIFEST = ROOT / "app" / "src" / "main" / "AndroidManifest.xml"


class AndroidReaderTrustTests(unittest.TestCase):
    def test_release_remains_blocked_until_device_verifies_signature_and_rollback(self):
        build = BUILD.read_text(encoding="utf-8")

        self.assertNotIn("releaseSignatureReady", build)
        self.assertNotIn("hasManifestString", build)
        self.assertIn(
            'buildConfigField("boolean", "QURAN_PACK_RELEASE_READY", "false")',
            build,
        )
        self.assertIn(
            "Android device-side trusted-key signature",
            build,
        )
        self.assertIn("anti-rollback persistence", build)

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
