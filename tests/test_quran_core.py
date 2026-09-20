import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

from tools.build_quran_core import build_pack, sha256_file
from tools.quran_core import (
    EXPECTED_AYAH_COUNTS,
    extract_tanzil_notice,
    load_production_source,
    normalize_search_diacritic_free,
    normalize_search_unicode,
)

ROOT = Path(__file__).resolve().parents[1]


class QuranCoreTests(unittest.TestCase):
    def test_expected_coordinate_total_is_6236(self):
        self.assertEqual(len(EXPECTED_AYAH_COUNTS), 114)
        self.assertEqual(sum(EXPECTED_AYAH_COUNTS), 6236)

    def test_pinned_tanzil_source_passes_full_coordinate_validation(self):
        source, artifact, rows = load_production_source(ROOT)
        self.assertEqual(source["status"], "production-approved")
        self.assertEqual(artifact.stat().st_size, 1384612)
        self.assertEqual(
            source["sha256"],
            "4b91f9e6e8ac645d039e4ed85b3be492e795232a31cd22d668ac58238722e26f",
        )
        self.assertEqual(len(rows), 6236)
        self.assertEqual((rows[0].surah, rows[0].ayah), (1, 1))
        self.assertEqual((rows[-1].surah, rows[-1].ayah), (114, 6))

    def test_notice_is_derived_from_preserved_source(self):
        source, artifact, _ = load_production_source(ROOT)
        notice = extract_tanzil_notice(artifact)
        self.assertTrue(source["attribution_required"])
        self.assertIn("Tanzil Quran Text (Uthmani, Version 1.1)", notice)
        self.assertIn("Creative Commons Attribution 3.0", notice)
        self.assertIn("CHANGING IT IS NOT ALLOWED", notice)
        self.assertIn("\n", notice)
        self.assertNotIn("\\n", notice)

    def test_search_normalization_never_mutates_display_input(self):
        original = "ٱلْحَمْدُ ۞"
        self.assertEqual(normalize_search_unicode(original), original)
        self.assertEqual(normalize_search_diacritic_free(original), "ٱلحمد")
        self.assertEqual(original, "ٱلْحَمْدُ ۞")

    def _copy_fixture_root(self, destination: Path) -> None:
        (destination / "schemas").mkdir(parents=True)
        shutil.copy2(ROOT / "schemas" / "content_v1.sql", destination / "schemas" / "content_v1.sql")

        source, artifact, _ = load_production_source(ROOT)
        artifact_rel = Path(source["vault_artifact"])
        copied_artifact = destination / artifact_rel
        copied_artifact.parent.mkdir(parents=True)
        shutil.copy2(artifact, copied_artifact)

        licence_rel = Path(source["licence_snapshot"])
        copied_licence = destination / licence_rel
        copied_licence.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / licence_rel, copied_licence)

        provenance_rel = Path(source["provenance"])
        copied_provenance = destination / provenance_rel
        copied_provenance.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / provenance_rel, copied_provenance)

        registry = {
            "schema_version": 1,
            "sources": [source],
        }
        registry_path = destination / "source-vault" / "registry.json"
        registry_path.parent.mkdir(parents=True, exist_ok=True)
        registry_path.write_text(
            json.dumps(registry, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def test_runtime_pack_carries_source_notice_and_attribution(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._copy_fixture_root(root)
            db_path, manifest_path = build_pack(
                root, Path("content-packs/quran-core/1.0.3")
            )
            source, artifact, _ = load_production_source(root)
            expected_notice = extract_tanzil_notice(artifact)
            provenance = json.loads((root / source["provenance"]).read_text(encoding="utf-8"))
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            notice_path = root / manifest["notice_path"]
            with sqlite3.connect(db_path) as connection:
                metadata = dict(connection.execute("SELECT key, value FROM pack_metadata"))

            self.assertEqual(manifest["content_version"], "1.0.3")
            self.assertEqual(manifest["schema_version"], 2)
            self.assertEqual(notice_path.read_text(encoding="utf-8"), expected_notice)
            self.assertEqual(metadata["source_notice"], expected_notice)
            self.assertEqual(metadata["source_attribution"], provenance["attribution"])
            self.assertEqual(metadata["source_url"], source["original_url"])
            self.assertEqual(metadata["source_licence_url"], provenance["licence_url"])
            self.assertEqual(metadata["source_licence_sha256"], source["licence_sha256"])
            self.assertEqual(
                metadata["source_provenance_sha256"], source["provenance_sha256"]
            )
            notice_hash = hashlib.sha256(expected_notice.encode("utf-8")).hexdigest()
            self.assertEqual(manifest["notice_sha256"], notice_hash)
            self.assertEqual(manifest["source_notice_sha256"], notice_hash)

    def test_direct_builder_cli_can_import_repo_tools(self):
        completed = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "build_quran_core.py"), "--help"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("pack directory", completed.stdout)

    def test_builder_is_byte_reproducible_for_identical_inputs(self):
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            root_a = Path(first)
            root_b = Path(second)
            self._copy_fixture_root(root_a)
            self._copy_fixture_root(root_b)

            db_a, manifest_a = build_pack(root_a, Path("content-packs/quran-core/1.0.3"))
            db_b, manifest_b = build_pack(root_b, Path("content-packs/quran-core/1.0.3"))

            self.assertEqual(sha256_file(db_a), sha256_file(db_b))
            manifest = json.loads(manifest_a.read_text(encoding="utf-8"))
            notice = root_a / manifest["notice_path"]
            self.assertTrue(notice.is_file())
            self.assertEqual(sha256_file(notice), manifest["notice_sha256"])
            _, source_artifact, _ = load_production_source(root_a)
            self.assertEqual(
                notice.read_text(encoding="utf-8"),
                extract_tanzil_notice(source_artifact),
            )


if __name__ == "__main__":
    unittest.main()
