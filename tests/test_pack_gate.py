import hashlib
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from tools.pack_gate import PackGateError, validate_manifest


class PackGateTests(unittest.TestCase):
    def _fixture(self, root: Path, *, source_status: str = "production-approved"):
        vault = root / "source-vault" / "quran" / "example" / "1.0"
        vault.mkdir(parents=True)
        source_artifact = vault / "raw.txt"
        source_artifact.write_bytes(b"source bytes")
        source_hash = hashlib.sha256(source_artifact.read_bytes()).hexdigest()

        registry = root / "source-vault" / "registry.json"
        registry.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "sources": [
                        {
                            "source_id": "quran.example.v1",
                            "source_name": "Example Quran Source",
                            "original_url": "https://example.invalid/quran",
                            "version": "1.0",
                            "status": source_status,
                            "licence_id": "Example-License",
                            "redistribution_allowed": True,
                            "vault_artifact": "source-vault/quran/example/1.0/raw.txt",
                            "sha256": source_hash,
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

        pack_dir = root / "content-packs" / "quran-example" / "1.0"
        pack_dir.mkdir(parents=True)
        built = pack_dir / "content.sqlite"
        built.write_bytes(b"deterministic pack bytes")
        built_hash = hashlib.sha256(built.read_bytes()).hexdigest()
        manifest = pack_dir / "manifest.json"
        manifest.write_text(
            json.dumps(
                {
                    "pack_id": "quran-example",
                    "schema_version": 1,
                    "content_version": "1.0",
                    "source_id": "quran.example.v1",
                    "source_name": "Example Quran Source",
                    "source_version": "1.0",
                    "source_vault_path": "source-vault/quran/example/1.0/raw.txt",
                    "source_sha256": source_hash,
                    "licence": "Example-License",
                    "edition": None,
                    "importer_version": "fixture-1",
                    "artifact_path": "content-packs/quran-example/1.0/content.sqlite",
                    "record_count": 1,
                    "review_status": "reviewed",
                    "built_sha256": built_hash,
                    "built_byte_size": built.stat().st_size,
                    "dependencies": [],
                    "signature": {"status": "unsigned"},
                }
            ),
            encoding="utf-8",
        )
        return registry, manifest, built

    def _v2_fixture(self, root: Path):
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
        provenance.write_text(
            json.dumps(provenance_data, sort_keys=True), encoding="utf-8"
        )
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
        notice.write_text(
            "# Example Quran Source\n# Example Project attribution notice\n",
            encoding="utf-8",
        )
        notice_hash = hashlib.sha256(notice.read_bytes()).hexdigest()

        built = pack_dir / "content.sqlite"
        metadata = {
            "pack_id": "quran-example",
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
            connection.commit()

        built_hash = hashlib.sha256(built.read_bytes()).hexdigest()
        manifest = pack_dir / "manifest.json"
        manifest.write_text(
            json.dumps(
                {
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
                    "built_sha256": built_hash,
                    "built_byte_size": built.stat().st_size,
                    "notice_path": "content-packs/quran-example/2.0/NOTICE.txt",
                    "notice_sha256": notice_hash,
                    "dependencies": [],
                    "signature": {"status": "unsigned"},
                }
            ),
            encoding="utf-8",
        )
        return registry, manifest, built, notice

    def test_reviewed_pack_from_approved_source_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _ = self._fixture(Path(tmp))
            validate_manifest(manifest, registry)

    def test_pack_from_unapproved_source_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _ = self._fixture(
                Path(tmp), source_status="awaiting-artifact"
            )
            with self.assertRaises(PackGateError):
                validate_manifest(manifest, registry)

    def test_tampered_runtime_pack_fails_hash_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, built = self._fixture(Path(tmp))
            built.write_bytes(b"tampered")
            with self.assertRaises(PackGateError):
                validate_manifest(manifest, registry)

    def test_source_identity_must_match_vault_registry(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _ = self._fixture(Path(tmp))
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["source_version"] = "latest"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaises(PackGateError):
                validate_manifest(manifest, registry)

    def test_approved_pack_requires_signature_material(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _ = self._fixture(Path(tmp))
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["review_status"] = "approved"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaises(PackGateError):
                validate_manifest(manifest, registry)

            data["signature"] = {
                "algorithm": "ed25519",
                "key_id": "release-key-1",
                "value": "fixture-signature",
            }
            manifest.write_text(json.dumps(data), encoding="utf-8")
            validate_manifest(manifest, registry)


    def test_schema_v2_pack_binds_notice_and_embedded_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _, _ = self._v2_fixture(Path(tmp))
            validate_manifest(manifest, registry)

    def test_schema_v2_tampered_notice_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _, notice = self._v2_fixture(Path(tmp))
            notice.write_text("tampered notice", encoding="utf-8")
            with self.assertRaisesRegex(PackGateError, "notice_sha256 mismatch"):
                validate_manifest(manifest, registry)

    def test_schema_v2_embedded_metadata_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, built, _ = self._v2_fixture(Path(tmp))
            with sqlite3.connect(built) as connection:
                connection.execute(
                    "UPDATE pack_metadata SET value = ? WHERE key = ?",
                    ("wrong attribution", "source_attribution"),
                )
                connection.commit()
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["built_sha256"] = hashlib.sha256(built.read_bytes()).hexdigest()
            data["built_byte_size"] = built.stat().st_size
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(PackGateError, "embedded pack metadata mismatch"):
                validate_manifest(manifest, registry)

    def test_runtime_pack_symlink_cannot_escape_content_packs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, built = self._fixture(root)
            outside = root / "outside.sqlite"
            outside.write_bytes(built.read_bytes())
            built.unlink()
            built.symlink_to(outside)
            with self.assertRaisesRegex(PackGateError, "resolves outside content-packs"):
                validate_manifest(manifest, registry)


if __name__ == "__main__":
    unittest.main()
