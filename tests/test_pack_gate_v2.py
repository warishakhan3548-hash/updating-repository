import hashlib
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from tools.pack_gate import PackGateError, validate_manifest


class PackGateV2Tests(unittest.TestCase):
    def _fixture(self, root: Path):
        vault = root / "source-vault" / "quran" / "example" / "2.0"
        vault.mkdir(parents=True)
        source_artifact = vault / "raw.txt"
        source_artifact.write_bytes(b"source bytes v2")
        source_hash = hashlib.sha256(source_artifact.read_bytes()).hexdigest()

        licence = vault / "LICENSE.txt"
        licence.write_text("example licence", encoding="utf-8")
        licence_hash = hashlib.sha256(licence.read_bytes()).hexdigest()

        provenance = vault / "provenance.json"
        provenance_data = {
            "source_id": "quran.example.v2",
            "source_name": "Example Quran Source",
            "original_url": "https://example.invalid/quran-v2",
            "version": "2.0",
            "licence_url": "https://example.invalid/licence",
            "attribution": "Example Project; https://example.invalid/",
        }
        provenance.write_text(json.dumps(provenance_data, sort_keys=True), encoding="utf-8")
        provenance_hash = hashlib.sha256(provenance.read_bytes()).hexdigest()

        registry = root / "source-vault" / "registry.json"
        registry.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "sources": [
                        {
                            "source_id": "quran.example.v2",
                            "source_name": "Example Quran Source",
                            "original_url": "https://example.invalid/quran-v2",
                            "version": "2.0",
                            "status": "production-approved",
                            "licence_id": "Example-License",
                            "redistribution_allowed": True,
                            "modification_allowed": False,
                            "attribution_required": True,
                            "vault_artifact": "source-vault/quran/example/2.0/raw.txt",
                            "licence_snapshot": "source-vault/quran/example/2.0/LICENSE.txt",
                            "provenance": "source-vault/quran/example/2.0/provenance.json",
                            "sha256": source_hash,
                            "licence_sha256": licence_hash,
                            "provenance_sha256": provenance_hash,
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

        pack_dir = root / "content-packs" / "quran-example" / "2.0"
        pack_dir.mkdir(parents=True)
        notice = pack_dir / "NOTICE.txt"
        notice.write_text("# exact preserved notice\n", encoding="utf-8")
        notice_hash = hashlib.sha256(notice.read_bytes()).hexdigest()

        built = pack_dir / "content.sqlite"
        metadata = {
            "pack_id": "quran-example",
            "schema_version": "2",
            "content_version": "2.0",
            "source_id": "quran.example.v2",
            "source_version": "2.0",
            "source_sha256": source_hash,
            "source_url": "https://example.invalid/quran-v2",
            "source_attribution": "Example Project; https://example.invalid/",
            "source_licence_url": "https://example.invalid/licence",
            "source_licence_sha256": licence_hash,
            "source_provenance_sha256": provenance_hash,
            "source_notice_sha256": notice_hash,
            "source_notice": notice.read_text(encoding="utf-8"),
        }
        with sqlite3.connect(built) as connection:
            connection.execute(
                "CREATE TABLE pack_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)"
            )
            connection.executemany(
                "INSERT INTO pack_metadata(key, value) VALUES (?, ?)",
                sorted(metadata.items()),
            )

        manifest = {
            "pack_id": "quran-example",
            "schema_version": 2,
            "content_version": "2.0",
            "source_id": "quran.example.v2",
            "source_name": "Example Quran Source",
            "source_version": "2.0",
            "source_vault_path": "source-vault/quran/example/2.0/raw.txt",
            "source_sha256": source_hash,
            "source_url": "https://example.invalid/quran-v2",
            "source_attribution": "Example Project; https://example.invalid/",
            "source_licence_url": "https://example.invalid/licence",
            "source_licence_sha256": licence_hash,
            "source_provenance_sha256": provenance_hash,
            "licence": "Example-License",
            "edition": None,
            "importer_version": "fixture-2",
            "artifact_path": "content-packs/quran-example/2.0/content.sqlite",
            "record_count": 1,
            "review_status": "reviewed",
            "built_sha256": hashlib.sha256(built.read_bytes()).hexdigest(),
            "built_byte_size": built.stat().st_size,
            "notice_path": "content-packs/quran-example/2.0/NOTICE.txt",
            "notice_sha256": notice_hash,
            "dependencies": [],
            "signature": {"status": "unsigned"},
        }
        manifest_path = pack_dir / "manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        return registry, manifest_path, built, notice, provenance

    def test_schema_v2_valid_pack_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _, _, _ = self._fixture(Path(tmp))
            validate_manifest(manifest, registry)

    def test_schema_v2_rejects_manifest_provenance_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _, _, _ = self._fixture(Path(tmp))
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["source_attribution"] = "different"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(PackGateError, "does not match Source Vault provenance"):
                validate_manifest(manifest, registry)

    def test_schema_v2_rejects_embedded_metadata_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, built, _, _ = self._fixture(Path(tmp))
            with sqlite3.connect(built) as connection:
                connection.execute(
                    "UPDATE pack_metadata SET value=? WHERE key='source_attribution'",
                    ("different",),
                )
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["built_sha256"] = hashlib.sha256(built.read_bytes()).hexdigest()
            data["built_byte_size"] = built.stat().st_size
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(PackGateError, "embedded pack metadata mismatch"):
                validate_manifest(manifest, registry)


if __name__ == "__main__":
    unittest.main()
