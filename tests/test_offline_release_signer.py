from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from tools.offline_release_signer import (
    ReleaseSigningError,
    load_encrypted_ed25519_private_key,
    public_key_record,
    require_private_key_outside_repo,
    sign_manifest,
    write_new_manifest,
)
from tools.pack_signatures import verify_approved_manifest


ROOT = Path(__file__).resolve().parents[1]
PASSWORD = b"correct horse battery staple"


class OfflineReleaseSignerTests(unittest.TestCase):
    def _encrypted_key_file(
        self,
        directory: Path,
        private_key: Ed25519PrivateKey,
        name: str = "release-key.pem",
    ) -> Path:
        path = directory / name
        path.write_bytes(
            private_key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.BestAvailableEncryption(PASSWORD),
            )
        )
        return path

    def _policy(
        self,
        directory: Path,
        private_keys: list[Ed25519PrivateKey],
        *,
        threshold: int = 1,
    ) -> Path:
        entries = [public_key_record(key) for key in private_keys]
        policy = {
            "schema_version": 1,
            "state": "active",
            "description": "test policy",
            "keys": {
                item["key_id"]: {
                    "algorithm": "ed25519",
                    "public_key": item["public_key"],
                    "status": "active",
                    "min_release_sequence": 1,
                    "max_release_sequence": None,
                }
                for item in entries
            },
            "roles": {
                "content-pack-release": {
                    "threshold": threshold,
                    "key_ids": [item["key_id"] for item in entries],
                }
            },
        }
        path = directory / "trusted_pack_keys.json"
        path.write_text(json.dumps(policy), encoding="utf-8")
        return path

    def _approved_manifest(self) -> dict:
        return {
            "pack_id": "quran-core",
            "content_version": "9.9.9-test",
            "review_status": "approved",
            "release_sequence": 7,
            "release_issued_at": "2026-09-21T00:00:00Z",
            "release_expires_at": "2027-09-21T00:00:00Z",
            "signature": {"status": "unsigned"},
            "source_attribution": "مصدر موثوق",
        }

    def test_encrypted_ed25519_key_loads_and_exposes_public_record_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            private = Ed25519PrivateKey.generate()
            path = self._encrypted_key_file(directory, private)

            loaded = load_encrypted_ed25519_private_key(
                path,
                PASSWORD,
                repo_root=ROOT,
            )
            record = public_key_record(loaded)

            self.assertEqual("ed25519", record["algorithm"])
            self.assertEqual(64, len(record["public_key"]))
            self.assertEqual(64, len(record["key_id"]))
            self.assertNotIn("private", record)

    def test_unencrypted_private_key_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "plain.pem"
            private = Ed25519PrivateKey.generate()
            path.write_bytes(
                private.private_bytes(
                    encoding=serialization.Encoding.PEM,
                    format=serialization.PrivateFormat.PKCS8,
                    encryption_algorithm=serialization.NoEncryption(),
                )
            )
            with self.assertRaisesRegex(ReleaseSigningError, "encrypted PKCS#8"):
                load_encrypted_ed25519_private_key(
                    path,
                    PASSWORD,
                    repo_root=ROOT,
                )

    def test_repository_private_key_path_is_refused_before_read(self):
        with self.assertRaisesRegex(ReleaseSigningError, "outside the repository"):
            require_private_key_outside_repo(
                ROOT / "private-release-key.pem",
                repo_root=ROOT,
            )

    def test_signer_requires_already_approved_manifest_and_authorized_active_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            private = Ed25519PrivateKey.generate()
            policy = self._policy(directory, [private])
            manifest = self._approved_manifest()
            manifest["review_status"] = "candidate"

            with self.assertRaisesRegex(ReleaseSigningError, "already be approved"):
                sign_manifest(manifest, private, policy)

            other = Ed25519PrivateKey.generate()
            manifest["review_status"] = "approved"
            with self.assertRaisesRegex(ReleaseSigningError, "not authorized"):
                sign_manifest(manifest, other, policy)

    def test_signer_refuses_approved_manifest_without_complete_freshness_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            private = Ed25519PrivateKey.generate()
            policy = self._policy(directory, [private])
            manifest = self._approved_manifest()
            manifest.pop("release_expires_at")

            with self.assertRaisesRegex(ReleaseSigningError, "release freshness"):
                sign_manifest(manifest, private, policy)

    def test_two_offline_keys_can_add_threshold_signatures_without_payload_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            first = Ed25519PrivateKey.generate()
            second = Ed25519PrivateKey.generate()
            policy = self._policy(directory, [first, second], threshold=2)
            manifest = self._approved_manifest()

            once = sign_manifest(manifest, first, policy)
            twice = sign_manifest(once, second, policy)

            self.assertEqual(2, len(twice["signature"]["signatures"]))
            self.assertEqual(2, verify_approved_manifest(twice, policy))
            self.assertEqual("مصدر موثوق", twice["source_attribution"])

    def test_same_key_cannot_sign_same_manifest_twice(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            private = Ed25519PrivateKey.generate()
            policy = self._policy(directory, [private])
            once = sign_manifest(self._approved_manifest(), private, policy)

            with self.assertRaisesRegex(ReleaseSigningError, "already signed"):
                sign_manifest(once, private, policy)

    def test_output_writer_is_create_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "signed.json"
            manifest = self._approved_manifest()
            write_new_manifest(output, manifest)
            with self.assertRaisesRegex(ReleaseSigningError, "refusing to overwrite"):
                write_new_manifest(output, manifest)


if __name__ == "__main__":
    unittest.main()
