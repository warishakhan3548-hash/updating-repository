import hashlib
import subprocess
import sys
import json
import tempfile
import unittest
from pathlib import Path

from tools.source_backup_gate import (
    SourceBackupGateError,
    require_verified_backup,
    validate_all,
)


class SourceBackupGateTests(unittest.TestCase):
    def _fixture(self, root: Path, *, status: str = "pending") -> tuple[Path, Path, str]:
        artifact = root / "source-vault" / "quran" / "example" / "1.0" / "raw.txt"
        artifact.parent.mkdir(parents=True)
        artifact.write_bytes(b"source bytes")
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()

        registry = root / "source-vault" / "registry.json"
        registry.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "sources": [
                        {
                            "source_id": "quran.example.v1",
                            "status": "production-approved",
                            "sha256": digest,
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

        policy = root / "policy"
        policy.mkdir()
        backup = policy / "source_backups.json"
        entry = {
            "source_id": "quran.example.v1",
            "artifact_sha256": digest,
            "status": status,
            "provider": None,
            "storage_class": None,
            "verified_at": None,
            "verification_method": None,
            "notes": "fixture",
        }
        if status == "verified":
            entry.update(
                {
                    "provider": "independent-provider",
                    "storage_class": "independent-cloud",
                    "verified_at": "2026-09-21T00:00:00Z",
                    "verification_method": "sha256",
                }
            )
        backup.write_text(
            json.dumps({"schema_version": 1, "backups": [entry]}),
            encoding="utf-8",
        )
        return registry, backup, digest

    def test_pending_backup_is_valid_tracking_but_not_release_ready(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, backup, digest = self._fixture(Path(tmp), status="pending")
            self.assertEqual(1, validate_all(registry, backup))
            with self.assertRaisesRegex(
                SourceBackupGateError, "independently verified source backup"
            ):
                require_verified_backup(registry, "quran.example.v1", digest)

    def test_verified_backup_passes_release_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, backup, digest = self._fixture(Path(tmp), status="verified")
            self.assertEqual(
                1,
                validate_all(registry, backup, require_verified=True),
            )
            require_verified_backup(registry, "quran.example.v1", digest)

    def test_duplicate_backup_json_key_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, backup, _ = self._fixture(Path(tmp), status="pending")
            text = backup.read_text(encoding="utf-8")
            backup.write_text(
                text.replace(
                    '"schema_version": 1,',
                    '"schema_version": 1, "schema_version": 1,',
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                SourceBackupGateError, "duplicate JSON object key"
            ):
                validate_all(registry, backup)

    def test_backup_hash_must_match_source_vault(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, backup, _ = self._fixture(Path(tmp), status="verified")
            data = json.loads(backup.read_text(encoding="utf-8"))
            data["backups"][0]["artifact_sha256"] = "0" * 64
            backup.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                SourceBackupGateError, "does not match Source Vault"
            ):
                validate_all(registry, backup)

    def test_production_source_cannot_disappear_from_backup_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, backup, _ = self._fixture(Path(tmp), status="pending")
            backup.write_text(
                json.dumps({"schema_version": 1, "backups": []}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                SourceBackupGateError, "missing backup attestation"
            ):
                validate_all(registry, backup)

    def test_pending_state_cannot_claim_verification_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, backup, _ = self._fixture(Path(tmp), status="pending")
            data = json.loads(backup.read_text(encoding="utf-8"))
            data["backups"][0]["provider"] = "claimed-provider"
            backup.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                SourceBackupGateError, "pending backup must not claim provider"
            ):
                validate_all(registry, backup)

    def test_verified_state_requires_timezone_aware_sha256_verification(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, backup, _ = self._fixture(Path(tmp), status="verified")
            data = json.loads(backup.read_text(encoding="utf-8"))
            data["backups"][0]["verified_at"] = "2026-09-21T00:00:00"
            backup.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                SourceBackupGateError, "must include a timezone"
            ):
                validate_all(registry, backup)

            data["backups"][0]["verified_at"] = "2026-09-21T00:00:00Z"
            data["backups"][0]["verification_method"] = "manual"
            backup.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                SourceBackupGateError, "must be checked by sha256"
            ):
                validate_all(registry, backup)

    def test_direct_cli_entrypoint_runs_from_repo_root(self):
        root = Path(__file__).resolve().parents[1]
        completed = subprocess.run(
            [
                sys.executable,
                str(root / "tools" / "source_backup_gate.py"),
                str(root / "source-vault" / "registry.json"),
            ],
            cwd=root,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn("Source backup gate OK", completed.stdout)


if __name__ == "__main__":
    unittest.main()
