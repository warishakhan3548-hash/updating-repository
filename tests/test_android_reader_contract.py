from __future__ import annotations

import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AndroidReaderContractTests(unittest.TestCase):
    def _contract(self) -> str:
        return (ROOT / "app/src/main/java/com/aaris/quran/data/QuranPackContract.kt").read_text(encoding="utf-8")

    def _string_constant(self, name: str) -> str:
        match = re.search(rf'const val {name} = "([^"]+)"', self._contract())
        self.assertIsNotNone(match, f"missing {name}")
        return match.group(1)

    def _int_constant(self, name: str) -> int:
        match = re.search(rf"const val {name} = ([0-9_]+)L?", self._contract())
        self.assertIsNotNone(match, f"missing {name}")
        return int(match.group(1).replace("_", ""))

    def test_android_contract_matches_verified_pack_manifest(self):
        manifest = json.loads(
            (ROOT / "content-packs/quran-core/1.0.3/manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["pack_id"], self._string_constant("PACK_ID"))
        self.assertEqual(manifest["content_version"], self._string_constant("CONTENT_VERSION"))
        self.assertEqual(manifest["built_sha256"], self._string_constant("BUILT_SHA256"))
        self.assertEqual(manifest["built_byte_size"], self._int_constant("BUILT_BYTE_SIZE"))
        self.assertEqual(manifest["record_count"], self._int_constant("RECORD_COUNT"))
        self.assertEqual(manifest["source_sha256"], self._string_constant("SOURCE_SHA256"))

    def test_android_reader_bundles_pack_without_duplicate_source_bytes(self):
        build_file = (ROOT / "app/build.gradle.kts").read_text(encoding="utf-8")
        self.assertIn('assets.srcDir(rootProject.file("content-packs/quran-core/1.0.3"))', build_file)
        self.assertFalse((ROOT / "app/src/main/assets/content.sqlite").exists())

    def test_android_reader_has_no_network_permission(self):
        manifest = (ROOT / "app/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
        self.assertNotIn("android.permission.INTERNET", manifest)
        self.assertNotIn("android.permission.ACCESS_NETWORK_STATE", manifest)

    def test_reader_opens_pack_read_only_and_renders_original_text_lane(self):
        repository = (ROOT / "app/src/main/java/com/aaris/quran/data/QuranRepository.kt").read_text(encoding="utf-8")
        self.assertIn("SQLiteDatabase.OPEN_READONLY", repository)
        self.assertIn("SELECT ayah, original_text FROM quran_ayah", repository)
        self.assertNotIn("search_unicode", repository)
        self.assertNotIn("search_diacritic_free", repository)


if __name__ == "__main__":
    unittest.main()
