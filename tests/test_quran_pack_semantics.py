import json
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest

from tools.pack_gate import PackGateError, sha256_file, validate_manifest
from tools.verify_quran_core_pack import verify_quran_core_pack

ROOT = Path(__file__).resolve().parents[1]
PACK_REL = Path("content-packs/quran-core/1.0.1")
MANIFEST_REL = PACK_REL / "manifest.json"
DB_REL = PACK_REL / "content.sqlite"


class QuranPackSemanticTests(unittest.TestCase):
    def test_committed_quran_core_matches_preserved_source_row_for_row(self):
        manifest = json.loads((ROOT / MANIFEST_REL).read_text(encoding="utf-8"))
        verify_quran_core_pack(ROOT, manifest)

    def _copy_release_fixture(self, destination: Path) -> tuple[Path, Path]:
        shutil.copytree(ROOT / "source-vault", destination / "source-vault")
        target_pack = destination / PACK_REL
        target_pack.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(ROOT / PACK_REL, target_pack)
        return (
            destination / "source-vault" / "registry.json",
            destination / MANIFEST_REL,
        )

    def _refresh_manifest_artifact_identity(
        self, manifest_path: Path, artifact_path: Path
    ) -> None:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["built_sha256"] = sha256_file(artifact_path)
        manifest["built_byte_size"] = artifact_path.stat().st_size
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
            encoding="utf-8",
        )

    def test_pack_gate_rejects_semantic_quran_tamper_even_with_fresh_file_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest_path = self._copy_release_fixture(root)
            artifact = root / DB_REL

            connection = sqlite3.connect(artifact)
            try:
                connection.execute("DROP TRIGGER quran_ayah_no_update")
                connection.execute(
                    """
                    UPDATE quran_ayah
                    SET original_text = original_text || ' تَحْرِيف'
                    WHERE surah = 1 AND ayah = 1
                    """
                )
                connection.execute(
                    """
                    CREATE TRIGGER quran_ayah_no_update
                    BEFORE UPDATE ON quran_ayah BEGIN
                      SELECT RAISE(ABORT, 'quran evidence is immutable');
                    END
                    """
                )
                connection.commit()
            finally:
                connection.close()

            # Simulate a broken or hostile release process that also refreshes
            # the outer artifact identity. The generic byte-integrity check now
            # accepts these altered bytes; source-to-pack semantic verification
            # must still reject the sacred-text change.
            self._refresh_manifest_artifact_identity(manifest_path, artifact)

            with self.assertRaisesRegex(
                PackGateError,
                r"Quran semantic verification failed: .*1:1",
            ):
                validate_manifest(manifest_path, registry)


if __name__ == "__main__":
    unittest.main()
