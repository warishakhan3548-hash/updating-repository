import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "content-packs" / "quran-core" / "1.0.4" / "manifest.json"
APP_BUILD = ROOT / "app" / "build.gradle.kts"
APP_MANIFEST = ROOT / "app" / "src" / "main" / "AndroidManifest.xml"
REPOSITORY = (
    ROOT
    / "app"
    / "src"
    / "main"
    / "java"
    / "com"
    / "aaris"
    / "quran"
    / "data"
    / "QuranReaderRepository.kt"
)
READER_CORE = ROOT / "tools" / "reader_core.py"


class AndroidReaderContractTests(unittest.TestCase):
    def test_debug_reader_packages_current_candidate_only_for_development(self):
        manifest = json.loads(PACK.read_text(encoding="utf-8"))
        build_file = APP_BUILD.read_text(encoding="utf-8")

        self.assertIn('getByName("debug").assets.srcDir("../content-packs/quran-core/1.0.4")', build_file)
        self.assertNotIn('getByName("main").assets.srcDir("../content-packs/quran-core/1.0.4")', build_file)
        self.assertEqual(manifest["pack_id"], "quran-core")
        self.assertEqual(manifest["schema_version"], 2)
        self.assertEqual(manifest["content_version"], "1.0.4")
        self.assertEqual(manifest["record_count"], 6236)
        self.assertEqual(manifest["review_status"], "candidate")
        self.assertEqual(
            manifest["built_sha256"],
            "492fcc4caa33b5ba64c94abce4d5f78d00232a99b777ea5e3bd70c338e19fa09",
        )

    def test_android_adapter_pins_the_same_provenance_bound_pack(self):
        source = REPOSITORY.read_text(encoding="utf-8")
        manifest = json.loads(PACK.read_text(encoding="utf-8"))

        pins = {
            "EXPECTED_SOURCE_SHA256": manifest["source_sha256"],
            "EXPECTED_SOURCE_LICENCE_SHA256": manifest["source_licence_sha256"],
            "EXPECTED_SOURCE_PROVENANCE_SHA256": manifest["source_provenance_sha256"],
            "EXPECTED_DATABASE_SHA256": manifest["built_sha256"],
            "EXPECTED_NOTICE_SHA256": manifest["notice_sha256"],
        }
        for constant_name, expected_hash in pins.items():
            self.assertIn(constant_name, source)
            self.assertIn(expected_hash, source)

        self.assertEqual(manifest["source_notice_sha256"], manifest["notice_sha256"])
        self.assertIn('manifest.getInt("schema_version")', source)
        self.assertIn('manifest.getString("review_status")', source)
        self.assertIn("if (!BuildConfig.DEBUG)", source)
        self.assertIn('reviewStatus == "approved"', source)

    def test_android_adapter_is_read_only_and_projects_original_text_only(self):
        source = REPOSITORY.read_text(encoding="utf-8")

        self.assertIn("SQLiteDatabase.OPEN_READONLY", source)
        self.assertIn(
            "SELECT ayah_id, surah, ayah, original_text",
            source,
        )
        self.assertNotIn("search_diacritic_free", source)
        self.assertNotIn("search_unicode", source)
        self.assertIn("canonicalAyahId", source)

    def test_android_layer_does_not_create_a_second_token_or_morphology_system(self):
        source = REPOSITORY.read_text(encoding="utf-8")
        core = READER_CORE.read_text(encoding="utf-8")

        self.assertIn("class ReaderCore", core)
        self.assertIn("SurfaceTapAnchor", core)
        self.assertNotIn("TokenID", source)
        self.assertNotIn("Lexeme", source)
        self.assertNotIn("morphology", source.lower())

    def test_core_reader_privacy_and_rtl_contract(self):
        manifest = APP_MANIFEST.read_text(encoding="utf-8")

        self.assertIn('android:supportsRtl="true"', manifest)
        self.assertIn('android:allowBackup="false"', manifest)
        self.assertIn('android:usesCleartextTraffic="false"', manifest)
        self.assertNotIn("android.permission.INTERNET", manifest)


if __name__ == "__main__":
    unittest.main()
