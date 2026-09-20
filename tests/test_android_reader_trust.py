import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "app" / "build.gradle.kts"
MANIFEST = ROOT / "app" / "src" / "main" / "AndroidManifest.xml"
PACKAGED_REPOSITORY = (
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
)
RELEASE_SEQUENCE_GUARD = PACKAGED_REPOSITORY.with_name("ReleaseSequenceGuard.kt")


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

    def test_release_runtime_persists_monotonic_sequence_outside_backup(self):
        build = BUILD.read_text(encoding="utf-8")
        repository = PACKAGED_REPOSITORY.read_text(encoding="utf-8")
        guard = RELEASE_SEQUENCE_GUARD.read_text(encoding="utf-8")

        self.assertIn("QURAN_PACK_RELEASE_SEQUENCE", build)
        self.assertIn("BuildConfig.QURAN_PACK_RELEASE_SEQUENCE", repository)
        self.assertIn("context.noBackupFilesDir", repository)
        self.assertIn("AtomicFile", guard)
        self.assertIn("quran-core.release-sequence", guard)
        self.assertIn("candidate >= highestAccepted", guard)

    def test_release_sequence_is_checked_before_pack_activation_and_recorded_after(self):
        repository = PACKAGED_REPOSITORY.read_text(encoding="utf-8")

        check_index = repository.index("releaseSequenceStore.requireAcceptable(candidate)")
        activate_index = repository.index("temporary.renameTo(target)")
        record_index = repository.index(
            "releaseSequence?.let(releaseSequenceStore::recordAccepted)",
            activate_index,
        )

        self.assertLess(check_index, activate_index)
        self.assertLess(activate_index, record_index)

    def test_reader_has_no_direct_network_permission(self):
        manifest = MANIFEST.read_text(encoding="utf-8")

        self.assertNotIn("android.permission.INTERNET", manifest)
        self.assertNotIn("android.permission.ACCESS_NETWORK_STATE", manifest)


if __name__ == "__main__":
    unittest.main()
