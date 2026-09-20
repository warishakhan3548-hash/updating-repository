import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from tools.vault_gate import VaultGateError, validate_registry


class VaultGateTests(unittest.TestCase):
    def _registry(self, root: Path, source: dict) -> Path:
        vault = root / "source-vault"
        vault.mkdir(parents=True, exist_ok=True)
        path = vault / "registry.json"
        path.write_text(
            json.dumps({"schema_version": 1, "sources": [source]}),
            encoding="utf-8",
        )
        return path

    def test_non_production_candidate_can_remain_unmirrored(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._registry(
                Path(tmp),
                {"source_id": "candidate", "status": "awaiting-artifact"},
            )
            validate_registry(path)

    def test_production_source_without_mirror_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._registry(
                Path(tmp),
                {
                    "source_id": "bad",
                    "status": "production-approved",
                    "redistribution_allowed": True,
                },
            )
            with self.assertRaises(VaultGateError):
                validate_registry(path)

    def test_valid_production_snapshot_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "source-vault" / "quran" / "example" / "1.0"
            (base / "raw").mkdir(parents=True)
            artifact = base / "raw" / "source.txt"
            artifact.write_bytes(b"immutable example")
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            (base / "LICENSE.txt").write_text("example licence", encoding="utf-8")
            provenance = {
                "source_id": "example",
                "original_url": "https://example.invalid/source",
                "version": "1.0",
                "retrieved_at": "2026-09-20T00:00:00Z",
                "sha256": digest,
                "byte_size": artifact.stat().st_size,
                "licence_id": "example-licence",
            }
            (base / "provenance.json").write_text(
                json.dumps(provenance), encoding="utf-8"
            )
            path = self._registry(
                root,
                {
                    "source_id": "example",
                    "status": "production-approved",
                    "redistribution_allowed": True,
                    "licence_id": "example-licence",
                    "vault_artifact": "source-vault/quran/example/1.0/raw/source.txt",
                    "licence_snapshot": "source-vault/quran/example/1.0/LICENSE.txt",
                    "provenance": "source-vault/quran/example/1.0/provenance.json",
                    "sha256": digest,
                    "byte_size": artifact.stat().st_size,
                },
            )
            validate_registry(path)

    def test_tampered_artifact_fails_hash_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "source-vault" / "quran" / "example" / "1.0"
            (base / "raw").mkdir(parents=True)
            artifact = base / "raw" / "source.txt"
            artifact.write_bytes(b"first")
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            (base / "LICENSE.txt").write_text("licence", encoding="utf-8")
            provenance = {
                "source_id": "example",
                "original_url": "https://example.invalid/source",
                "version": "1.0",
                "retrieved_at": "2026-09-20T00:00:00Z",
                "sha256": digest,
                "byte_size": artifact.stat().st_size,
                "licence_id": "example-licence",
            }
            (base / "provenance.json").write_text(
                json.dumps(provenance), encoding="utf-8"
            )
            path = self._registry(
                root,
                {
                    "source_id": "example",
                    "status": "production-approved",
                    "redistribution_allowed": True,
                    "licence_id": "example-licence",
                    "vault_artifact": "source-vault/quran/example/1.0/raw/source.txt",
                    "licence_snapshot": "source-vault/quran/example/1.0/LICENSE.txt",
                    "provenance": "source-vault/quran/example/1.0/provenance.json",
                    "sha256": digest,
                    "byte_size": artifact.stat().st_size,
                },
            )
            artifact.write_bytes(b"tampered")
            with self.assertRaises(VaultGateError):
                validate_registry(path)


if __name__ == "__main__":
    unittest.main()
