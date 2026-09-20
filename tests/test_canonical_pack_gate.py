import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from tools.pack_gate import PackGateError, validate_manifest


class CanonicalPackGateTests(unittest.TestCase):
    def _fixture(self, root: Path):
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
                            "version": "1.0",
                            "status": "production-approved",
                            "licence_id": "Example-License",
                            "redistribution_allowed": True,
                            "attribution_required": False,
                            "vault_artifact": "source-vault/quran/example/1.0/raw.txt",
                            "sha256": source_hash,
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

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
        canonical_manifest_hash = hashlib.sha256(
            canonical_manifest.read_bytes()
        ).hexdigest()

        pack_dir = root / "content-packs" / "quran-example" / "1.1"
        pack_dir.mkdir(parents=True)
        built = pack_dir / "content.sqlite"
        built.write_bytes(b"deterministic pack bytes")
        built_hash = hashlib.sha256(built.read_bytes()).hexdigest()
        manifest = pack_dir / "manifest.json"
        manifest_data = {
            "pack_id": "quran-example",
            "schema_version": 2,
            "content_schema_version": 1,
            "content_version": "1.1",
            "source_id": "quran.example.v1",
            "source_name": "Example Quran Source",
            "source_version": "1.0",
            "source_vault_path": "source-vault/quran/example/1.0/raw.txt",
            "source_sha256": source_hash,
            "licence": "Example-License",
            "edition": None,
            "importer_version": "fixture-2",
            "artifact_path": "content-packs/quran-example/1.1/content.sqlite",
            "record_count": 1,
            "review_status": "reviewed",
            "built_sha256": built_hash,
            "built_byte_size": built.stat().st_size,
            "dependencies": [],
            "signature": {"status": "unsigned"},
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
            "byte_reproducibility_scope": (
                "Identical bytes require the same canonical input, importer, "
                "Python and SQLite toolchain."
            ),
        }
        manifest.write_text(
            json.dumps(manifest_data, sort_keys=True, indent=2) + "\n",
            encoding="utf-8",
        )
        return registry, manifest, canonical_artifact, canonical_manifest

    def test_v2_pack_with_canonical_binding_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _, _ = self._fixture(Path(tmp))
            validate_manifest(manifest, registry)

    def test_tampered_canonical_artifact_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, canonical, _ = self._fixture(Path(tmp))
            canonical.write_text('{"id":"tampered"}\n', encoding="utf-8")
            with self.assertRaisesRegex(PackGateError, "canonical artifact"):
                validate_manifest(manifest, registry)

    def test_canonical_source_identity_cannot_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _, canonical_manifest = self._fixture(Path(tmp))
            data = json.loads(canonical_manifest.read_text(encoding="utf-8"))
            data["source_version"] = "other"
            canonical_manifest.write_text(
                json.dumps(data, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            )
            pack = json.loads(manifest.read_text(encoding="utf-8"))
            pack["canonical"]["manifest_sha256"] = hashlib.sha256(
                canonical_manifest.read_bytes()
            ).hexdigest()
            manifest.write_text(
                json.dumps(pack, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackGateError, "source_version"):
                validate_manifest(manifest, registry)

    def test_canonical_artifact_cannot_borrow_another_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, canonical, canonical_manifest = self._fixture(root)
            other = root / "canonical" / "other" / "1.0" / "records.jsonl"
            other.parent.mkdir(parents=True)
            other.write_bytes(canonical.read_bytes())
            canonical.unlink()
            canonical.symlink_to(other)
            pack = json.loads(manifest.read_text(encoding="utf-8"))
            pack["canonical"]["artifact_sha256"] = hashlib.sha256(
                other.read_bytes()
            ).hexdigest()
            pack["canonical"]["artifact_byte_size"] = other.stat().st_size
            manifest.write_text(
                json.dumps(pack, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackGateError, "canonical artifact must resolve"):
                validate_manifest(manifest, registry)


if __name__ == "__main__":
    unittest.main()
