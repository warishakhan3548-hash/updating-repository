import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

from tools.build_quran_core import build_pack, sha256_file
from tools.quran_canonical import (
    build_canonical,
    load_canonical,
    sha256_file as sha256_canonical_file,
)
from tools.quran_core import (
    EXPECTED_AYAH_COUNTS,
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

    def test_search_normalization_never_mutates_display_input(self):
        original = "ٱلْحَمْدُ ۞"
        self.assertEqual(normalize_search_unicode(original), original)
        self.assertEqual(normalize_search_diacritic_free(original), "ٱلحمد")
        self.assertEqual(original, "ٱلْحَمْدُ ۞")

    def _copy_fixture_root(self, destination: Path) -> None:
        (destination / "schemas").mkdir(parents=True)
        shutil.copy2(
            ROOT / "schemas" / "content_v1.sql",
            destination / "schemas" / "content_v1.sql",
        )

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

        registry = {"schema_version": 1, "sources": [source]}
        registry_path = destination / "source-vault" / "registry.json"
        registry_path.parent.mkdir(parents=True, exist_ok=True)
        registry_path.write_text(
            json.dumps(registry, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def test_direct_builder_clis_can_import_repo_tools(self):
        for script in ("build_quran_canonical.py", "build_quran_core.py"):
            completed = subprocess.run(
                [sys.executable, str(ROOT / "tools" / script), "--help"],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("repository root", completed.stdout)

    def test_canonical_artifact_is_byte_reproducible(self):
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            root_a = Path(first)
            root_b = Path(second)
            self._copy_fixture_root(root_a)
            self._copy_fixture_root(root_b)

            artifact_a, manifest_a = build_canonical(root_a)
            artifact_b, manifest_b = build_canonical(root_b)

            self.assertEqual(sha256_canonical_file(artifact_a), sha256_canonical_file(artifact_b))
            self.assertEqual(sha256_canonical_file(manifest_a), sha256_canonical_file(manifest_b))

            canonical = load_canonical(root_a)
            self.assertEqual(len(canonical.rows), 6236)
            self.assertEqual(canonical.rows[0].ayah_id, "qa:001:001")
            self.assertEqual(canonical.rows[-1].ayah_id, "qa:114:006")

    def test_runtime_pack_is_built_from_canonical_binding(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._copy_fixture_root(root)
            build_canonical(root)
            db_path, manifest_path = build_pack(
                root, Path("content-packs/quran-core/1.1.0")
            )

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(manifest["schema_version"], 2)
            self.assertEqual(manifest["content_schema_version"], 1)
            self.assertEqual(manifest["record_count"], 6236)
            self.assertEqual(
                manifest["canonical"]["artifact_sha256"],
                sha256_canonical_file(root / manifest["canonical"]["artifact_path"]),
            )
            self.assertTrue(manifest["build_toolchain"]["python_version"])
            self.assertTrue(manifest["build_toolchain"]["sqlite_version"])

            with sqlite3.connect(db_path) as connection:
                payload = json.loads(
                    connection.execute(
                        "SELECT payload_json FROM source_assertion WHERE source_id = ?",
                        ("quran.tanzil.uthmani.v1.1",),
                    ).fetchone()[0]
                )
            self.assertEqual(
                payload["canonical_artifact"],
                manifest["canonical"]["artifact_path"],
            )
            self.assertEqual(
                payload["canonical_sha256"],
                manifest["canonical"]["artifact_sha256"],
            )

    def test_runtime_pack_is_byte_reproducible_with_same_toolchain(self):
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            root_a = Path(first)
            root_b = Path(second)
            self._copy_fixture_root(root_a)
            self._copy_fixture_root(root_b)
            build_canonical(root_a)
            build_canonical(root_b)

            db_a, manifest_a = build_pack(root_a, Path("content-packs/quran-core/1.1.0"))
            db_b, _ = build_pack(root_b, Path("content-packs/quran-core/1.1.0"))

            self.assertEqual(sha256_file(db_a), sha256_file(db_b))
            manifest = json.loads(manifest_a.read_text(encoding="utf-8"))
            notice = root_a / manifest["notice_path"]
            self.assertTrue(notice.is_file())
            self.assertEqual(sha256_file(notice), manifest["notice_sha256"])
            self.assertIn("Tanzil Quran Text", notice.read_text(encoding="utf-8"))
            self.assertIn("canonical JSONL hash", manifest["byte_reproducibility_scope"])


if __name__ == "__main__":
    unittest.main()
