import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from tools.pack_gate import PackGateError, validate_manifest


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class PackGateTests(unittest.TestCase):
    def _fixture(self, root: Path, *, source_status: str = "production-approved", schema_version: int = 1):
        vault = root / "source-vault" / "quran" / "example" / "1.0"
        vault.mkdir(parents=True)
        source_artifact = vault / "raw.txt"
        source_artifact.write_bytes(b"source bytes")
        source_hash = sha256_bytes(source_artifact.read_bytes())

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
        built_hash = sha256_bytes(built.read_bytes())

        data = {
            "pack_id": "quran-example",
            "schema_version": schema_version,
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

        if schema_version == 2:
            canonical_dir = root / "canonical" / "quran-example" / "1.0"
            canonical_dir.mkdir(parents=True)
            canonical_artifact = canonical_dir / "records.jsonl"
            canonical_artifact.write_text('{"id":"row-1"}\n', encoding="utf-8")
            canonical_hash = hashlib.sha256(canonical_artifact.read_bytes()).hexdigest()
            canonical_manifest = canonical_dir / "manifest.json"
            canonical_manifest_data = {
                "canonical_id": "quran-example-records",
                "schema_version": 1,
                "canonical_version": "1.0",
                "generator_version": "fixture-canonical-1",
                "artifact_path": "canonical/quran-example/1.0/records.jsonl",
                "artifact_sha256": canonical_hash,
                "artifact_byte_size": canonical_artifact.stat().st_size,
                "record_count": 1,
                "source_id": "quran.example.v1",
                "source_name": "Example Quran Source",
                "source_version": "1.0",
                "source_vault_path": "source-vault/quran/example/1.0/raw.txt",
                "source_sha256": source_hash,
                "licence": "Example-License",
            }
            canonical_manifest.write_text(
                json.dumps(canonical_manifest_data, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            )
            canonical_manifest_hash = hashlib.sha256(canonical_manifest.read_bytes()).hexdigest()
            data.update(
                {
                    "content_schema_version": 1,
                    "canonical": {
                        "canonical_id": "quran-example-records",
                        "canonical_version": "1.0",
                        "generator_version": "fixture-canonical-1",
                        "manifest_path": "canonical/quran-example/1.0/manifest.json",
                        "manifest_sha256": canonical_manifest_hash,
                        "artifact_path": "canonical/quran-example/1.0/records.jsonl",
                        "artifact_sha256": canonical_hash,
                        "artifact_byte_size": canonical_artifact.stat().st_size,
                        "record_count": 1,
                    },
                    "build_toolchain": {
                        "python_implementation": "CPython",
                        "python_version": "3.13.15",
                        "sqlite_version": "3.49.1",
                    },
                    "byte_reproducibility_scope": "Identical bytes require the same canonical input, importer, Python and SQLite toolchain.",
                }
            )

        manifest = pack_dir / "manifest.json"
        manifest.write_text(json.dumps(data, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        return registry, manifest, built

    def test_reviewed_v1_pack_from_approved_source_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _ = self._fixture(Path(tmp))
            validate_manifest(manifest, registry)

    def test_reviewed_v2_pack_with_canonical_binding_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _ = self._fixture(Path(tmp), schema_version=2)
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

    def test_v2_tampered_canonical_artifact_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root, schema_version=2)
            canonical = root / "canonical" / "quran-example" / "1.0" / "records.jsonl"
            canonical.write_text('{"id":"tampered"}\n', encoding="utf-8")
            with self.assertRaises(PackGateError):
                validate_manifest(manifest, registry)

    def test_v2_canonical_source_must_match_pack_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root, schema_version=2)
            canonical_manifest = root / "canonical" / "quran-example" / "1.0" / "manifest.json"
            data = json.loads(canonical_manifest.read_text(encoding="utf-8"))
            data["source_version"] = "other"
            canonical_manifest.write_text(
                json.dumps(data, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            )
            manifest_data = json.loads(manifest.read_text(encoding="utf-8"))
            manifest_data["canonical"]["manifest_sha256"] = hashlib.sha256(
                canonical_manifest.read_bytes()
            ).hexdigest()
            manifest.write_text(
                json.dumps(manifest_data, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            )
            with self.assertRaises(PackGateError):
                validate_manifest(manifest, registry)


if __name__ == "__main__":
    unittest.main()
