import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AndroidReaderContractTests(unittest.TestCase):
    def test_reader_packages_the_pinned_quran_core_candidate(self):
        manifest = json.loads(
            (ROOT / "content-packs" / "quran-core" / "1.0.1" / "manifest.json")
            .read_text(encoding="utf-8")
        )
        build_file = (ROOT / "app" / "build.gradle.kts").read_text(encoding="utf-8")

        self.assertIn("../content-packs/quran-core/1.0.1", build_file)
        self.assertEqual(manifest["pack_id"], "quran-core")
        self.assertEqual(manifest["content_version"], "1.0.1")
        self.assertEqual(manifest["record_count"], 6236)
        self.assertEqual(
            manifest["built_sha256"],
            "34df2de57790226382d7693f1f64df78a78d446b83754d714e72787cc32f7b58",
        )
        self.assertEqual(manifest["review_status"], "candidate")

    def test_reader_opens_evidence_database_read_only_and_renders_original_text(self):
        store = (
            ROOT / "app" / "src" / "main" / "java" / "com" / "aaris" / "quran"
            / "data" / "QuranPackStore.kt"
        ).read_text(encoding="utf-8")

        self.assertIn("SQLiteDatabase.OPEN_READONLY", store)
        self.assertIn("original_text", store)
        self.assertNotIn("search_diacritic_free", store)
        self.assertIn('manifest.getString("built_sha256")', store)

    def test_manifest_keeps_core_reader_private_and_rtl_capable(self):
        manifest = (
            ROOT / "app" / "src" / "main" / "AndroidManifest.xml"
        ).read_text(encoding="utf-8")

        self.assertIn('android:supportsRtl="true"', manifest)
        self.assertIn('android:allowBackup="false"', manifest)
        self.assertIn('android:usesCleartextTraffic="false"', manifest)
        self.assertNotIn("android.permission.INTERNET", manifest)

    def test_no_fake_pack_promotion_is_embedded_in_reader(self):
        store = (
            ROOT / "app" / "src" / "main" / "java" / "com" / "aaris" / "quran"
            / "data" / "QuranPackStore.kt"
        ).read_text(encoding="utf-8")
        self.assertNotIn('"review_status" == "approved"', store)
        self.assertNotIn("release-key", store)


if __name__ == "__main__":
    unittest.main()
