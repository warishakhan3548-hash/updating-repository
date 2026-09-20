from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "app" / "build.gradle.kts"
MANIFEST = ROOT / "app" / "src" / "main" / "AndroidManifest.xml"


class AndroidReaderTrustTests(unittest.TestCase):
    def test_release_does_not_treat_signature_fields_as_verification(self):
        build = BUILD.read_text(encoding="utf-8")

        self.assertNotIn("releaseSignatureReady", build)
        self.assertNotIn("hasManifestString", build)
        self.assertIn('tasks.registering(Exec::class)', build)
        self.assertIn('"tools/pack_gate.py"', build)
        self.assertIn('"policy/trusted_pack_keys.json"', build)
        self.assertIn(
            'buildConfigField("boolean", "QURAN_PACK_RELEASE_READY", "true")',
            build,
        )

    def test_release_still_requires_approved_review_status_first(self):
        build = BUILD.read_text(encoding="utf-8")

        self.assertIn('check(packReviewStatus == "approved")', build)
        self.assertIn("not approved", build)
        self.assertIn(
            'it.name == "preReleaseBuild"',
            build,
        )
        self.assertIn("dependsOn(verifyReleaseQuranPack)", build)

    def test_debug_never_claims_release_pack_readiness(self):
        build = BUILD.read_text(encoding="utf-8")

        self.assertIn(
            'getByName("debug") {',
            build,
        )
        self.assertIn(
            'buildConfigField("boolean", "QURAN_PACK_RELEASE_READY", "false")',
            build,
        )

    def test_reader_has_no_direct_network_permission(self):
        manifest = MANIFEST.read_text(encoding="utf-8")

        self.assertNotIn("android.permission.INTERNET", manifest)
        self.assertNotIn("android.permission.ACCESS_NETWORK_STATE", manifest)


if __name__ == "__main__":
    unittest.main()
