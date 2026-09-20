import json
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest

from tools.build_quran_core import build_pack
from tools.pack_gate import PackGateError, sha256_file, validate_manifest
from tools.quran_canonical import build_canonical
from tools.quran_core import load_production_source
from tools.verify_quran_core_pack import (
    latest_semantic_manifest,
    verify_quran_core_pack,
)

ROOT = Path(__file__).resolve().parents[1]
LATEST_MANIFEST = latest_semantic_manifest(ROOT)
PACK_REL = LATEST_MANIFEST.parent.relative_to(ROOT)
MANIFEST_REL = PACK_REL / "manifest.json"
DB_REL = PACK_REL / "content.sqlite"


class PublishedQuranPackSemanticTests(unittest.TestCase):
    def test_current_quran_core_matches_preserved_source(self):
        manifest = json.loads((ROOT / MANIFEST_REL).read_text(encoding="utf-8"))
        verify_quran_core_pack(ROOT, manifest)

    def _copy_release_fixture(
        self,
        destination: Path,
        source_root: Path = ROOT,
        manifest_rel: Path = MANIFEST_REL,
    ) -> tuple[Path, Path]:
        pack_rel = manifest_rel.parent
        shutil.copytree(source_root / "source-vault", destination / "source-vault")
        (destination / "schemas").mkdir(parents=True)
        shutil.copy2(
            source_root / "schemas" / "content_v1.sql",
            destination / "schemas" / "content_v1.sql",
        )
        target_pack = destination / pack_rel
        target_pack.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source_root / pack_rel, target_pack)

        manifest = json.loads((source_root / manifest_rel).read_text(encoding="utf-8"))
        if manifest.get("schema_version") == 3:
            canonical = manifest.get("canonical")
            if not isinstance(canonical, dict):
                self.fail("schema-v3 published pack is missing canonical binding")
            for field in ("manifest_path", "artifact_path"):
                rel = Path(canonical[field])
                target = destination / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source_root / rel, target)

        return (
            destination / "source-vault" / "registry.json",
            destination / manifest_rel,
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

    def test_pack_gate_rejects_quran_tamper_even_with_fresh_file_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest_path = self._copy_release_fixture(root)
            artifact = root / DB_REL

            connection = sqlite3.connect(artifact)
            try:
                trigger_sql = connection.execute(
                    """
                    SELECT sql
                    FROM sqlite_schema
                    WHERE type = 'trigger' AND name = 'quran_ayah_no_update'
                    """
                ).fetchone()[0]
                connection.execute("DROP TRIGGER quran_ayah_no_update")
                connection.execute(
                    """
                    UPDATE quran_ayah
                    SET original_text = original_text || ' تَحْرِيف'
                    WHERE surah = 1 AND ayah = 1
                    """
                )
                connection.execute(trigger_sql)
                connection.commit()
            finally:
                connection.close()

            self._refresh_manifest_artifact_identity(manifest_path, artifact)

            with self.assertRaisesRegex(
                PackGateError,
                r"Quran semantic verification failed: .*1:1",
            ):
                validate_manifest(manifest_path, registry)

    def test_pack_gate_rejects_schema_tamper_even_with_fresh_file_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest_path = self._copy_release_fixture(root)
            artifact = root / DB_REL

            connection = sqlite3.connect(artifact)
            try:
                connection.execute("DROP INDEX idx_quran_token_ayah")
                connection.commit()
            finally:
                connection.close()

            self._refresh_manifest_artifact_identity(manifest_path, artifact)

            with self.assertRaisesRegex(
                PackGateError,
                r"Quran semantic verification failed: .*canonical content_v1.sql",
            ):
                validate_manifest(manifest_path, registry)


class SchemaV3QuranPackSemanticTests(unittest.TestCase):
    def _copy_source_fixture(self, destination: Path) -> None:
        (destination / "schemas").mkdir(parents=True)
        shutil.copy2(
            ROOT / "schemas" / "content_v1.sql",
            destination / "schemas" / "content_v1.sql",
        )
        source, artifact, _ = load_production_source(ROOT)
        for field in ("vault_artifact", "licence_snapshot", "provenance"):
            rel = Path(source[field])
            target = destination / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel if field != "vault_artifact" else artifact, target)
        registry = destination / "source-vault" / "registry.json"
        registry.parent.mkdir(parents=True, exist_ok=True)
        registry.write_text(
            json.dumps({"schema_version": 1, "sources": [source]}, indent=2) + "\n",
            encoding="utf-8",
        )

    def _build(self, root: Path) -> tuple[Path, Path, Path]:
        self._copy_source_fixture(root)
        build_canonical(root)
        artifact, manifest = build_pack(
            root, Path("content-packs/quran-core/1.1.0")
        )
        return root / "source-vault" / "registry.json", manifest, artifact

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

    def test_schema_v3_quran_core_matches_source_and_canonical_layer(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest_path, _ = self._build(root)
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            verify_quran_core_pack(root, manifest)
            validate_manifest(manifest_path, registry)

    def test_schema_v3_release_fixture_carries_canonical_dependency(self):
        with tempfile.TemporaryDirectory() as build_tmp, tempfile.TemporaryDirectory() as copy_tmp:
            build_root = Path(build_tmp)
            copy_root = Path(copy_tmp)
            _, manifest_path, _ = self._build(build_root)
            manifest_rel = manifest_path.relative_to(build_root)

            helper = PublishedQuranPackSemanticTests()
            registry, copied_manifest = helper._copy_release_fixture(
                copy_root,
                source_root=build_root,
                manifest_rel=manifest_rel,
            )

            validate_manifest(copied_manifest, registry)

    def test_schema_v3_runtime_tamper_cannot_be_legitimized_by_rehashing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest_path, artifact = self._build(root)

            connection = sqlite3.connect(artifact)
            try:
                trigger_sql = connection.execute(
                    """
                    SELECT sql
                    FROM sqlite_schema
                    WHERE type = 'trigger' AND name = 'quran_ayah_no_update'
                    """
                ).fetchone()[0]
                connection.execute("DROP TRIGGER quran_ayah_no_update")
                connection.execute(
                    """
                    UPDATE quran_ayah
                    SET original_text = original_text || ' تَحْرِيف'
                    WHERE surah = 1 AND ayah = 1
                    """
                )
                connection.execute(trigger_sql)
                connection.commit()
            finally:
                connection.close()

            self._refresh_manifest_artifact_identity(manifest_path, artifact)

            with self.assertRaisesRegex(
                PackGateError,
                r"Quran semantic verification failed: .*1:1",
            ):
                validate_manifest(manifest_path, registry)


if __name__ == "__main__":
    unittest.main()
