from __future__ import annotations

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "apps" / "android-reader"
PACK_PROPERTIES = APP / "reader-pack.properties"


def read_properties(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class AndroidReaderContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.pack = read_properties(PACK_PROPERTIES)
        self.pack_dir = (
            ROOT
            / "content-packs"
            / "quran-core"
            / self.pack["content_version"]
        )
        self.manifest = json.loads(
            (self.pack_dir / "manifest.json").read_text(encoding="utf-8")
        )

    def test_android_reader_is_bound_to_exact_existing_pack(self) -> None:
        expected = {
            "pack_id": self.manifest["pack_id"],
            "content_version": self.manifest["content_version"],
            "review_status": self.manifest["review_status"],
            "built_sha256": self.manifest["built_sha256"],
            "source_sha256": self.manifest["source_sha256"],
            "notice_sha256": self.manifest["notice_sha256"],
        }
        self.assertEqual(expected, self.pack)
        self.assertEqual(
            self.pack["built_sha256"],
            sha256(self.pack_dir / "content.sqlite"),
        )
        self.assertEqual(
            self.pack["notice_sha256"],
            sha256(self.pack_dir / "NOTICE.txt"),
        )

    def test_candidate_pack_cannot_become_android_release(self) -> None:
        build = (APP / "app" / "build.gradle.kts").read_text(encoding="utf-8")
        self.assertEqual("candidate", self.pack["review_status"])
        self.assertIn('packReviewStatus != "approved"', build)
        self.assertIn("Release blocked:", build)

    def test_reader_has_no_direct_network_permission_or_duplicate_pack(self) -> None:
        manifest = (
            APP / "app" / "src" / "main" / "AndroidManifest.xml"
        ).read_text(encoding="utf-8")
        build = (APP / "app" / "build.gradle.kts").read_text(encoding="utf-8")
        self.assertNotIn("android.permission.INTERNET", manifest)
        self.assertIn('assets.srcDir(packDir)', build)
        self.assertFalse((APP / "app" / "src" / "main" / "assets").exists())

    def test_reader_projection_is_original_text_only_and_read_only(self) -> None:
        repository = (
            APP
            / "app"
            / "src"
            / "main"
            / "java"
            / "com"
            / "aaris"
            / "quran"
            / "data"
            / "QuranRepository.kt"
        ).read_text(encoding="utf-8")
        self.assertIn("SQLiteDatabase.OPEN_READONLY", repository)
        query = repository.split('internal const val READ_SURAH_SQL =', 1)[1]
        self.assertIn("original_text", query)
        self.assertNotIn("search_unicode", query)
        self.assertNotIn("search_diacritic_free", query)

    def test_manifest_does_not_enable_cloud_backup_by_default(self) -> None:
        manifest = (
            APP / "app" / "src" / "main" / "AndroidManifest.xml"
        ).read_text(encoding="utf-8")
        self.assertIn('android:allowBackup="false"', manifest)


if __name__ == "__main__":
    unittest.main()
