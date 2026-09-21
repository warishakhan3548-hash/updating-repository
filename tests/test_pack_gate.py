import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from tools.pack_gate import PackGateError, validate_manifest
from tools.pack_signatures import (
    canonical_manifest_payload,
    key_id_for_ed25519_public_key,
)


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
                            "commercial_use_allowed": True,
                            "release_requirements": {
                                "latest_upstream_version_required": False,
                                "version_check_url": "https://example.invalid/versions",
                                "historical_snapshot_retention_status": "verified-allowed",
                            },
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
        policy = root / "policy"
        policy.mkdir(exist_ok=True)
        (policy / "source_backups.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "backups": [
                        {
                            "source_id": "quran.example.v1",
                            "artifact_sha256": source_hash,
                            "status": "verified",
                            "provider": "test-independent-provider",
                            "storage_class": "independent-cloud",
                            "verified_at": "2026-09-21T00:00:00Z",
                            "verification_method": "sha256",
                            "notes": "test fixture",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        return registry, manifest, built

    def test_reviewed_pack_from_approved_source_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _ = self._fixture(Path(tmp))
            validate_manifest(manifest, registry)

    def test_pack_manifest_duplicate_json_key_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _ = self._fixture(Path(tmp))
            text = manifest.read_text(encoding="utf-8")
            manifest.write_text(
                text.replace(
                    "{",
                    '{"pack_id":"ambiguous",',
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                PackGateError, "duplicate JSON object key"
            ):
                validate_manifest(manifest, registry)

    def test_pack_from_unapproved_source_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _ = self._fixture(
                Path(tmp), source_status="awaiting-artifact"
            )
            with self.assertRaises(PackGateError):
                validate_manifest(manifest, registry)

    def test_pack_from_noncommercial_source_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            data = json.loads(registry.read_text(encoding="utf-8"))
            data["sources"][0]["commercial_use_allowed"] = False
            registry.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError, "lacks commercial-use approval"
            ):
                validate_manifest(manifest, registry)

    def test_pack_from_source_with_unknown_commercial_permission_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            data = json.loads(registry.read_text(encoding="utf-8"))
            data["sources"][0]["commercial_use_allowed"] = None
            registry.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError, "lacks commercial-use approval"
            ):
                validate_manifest(manifest, registry)

    def test_pack_source_requires_archival_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            data = json.loads(registry.read_text(encoding="utf-8"))
            data["sources"][0].pop("release_requirements")
            registry.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError, "requires complete Source Vault release_requirements"
            ):
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

    def test_approved_pack_requires_signed_release_freshness_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _ = self._fixture(Path(tmp))
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["review_status"] = "approved"
            data["release_sequence"] = 1
            manifest.write_text(json.dumps(data), encoding="utf-8")

            with self.assertRaisesRegex(PackGateError, "release freshness"):
                validate_manifest(manifest, registry)

    def test_approved_pack_rejects_unsigned_and_legacy_fake_signatures(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _ = self._fixture(Path(tmp))
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["review_status"] = "approved"
            data["release_sequence"] = 1
            data["release_issued_at"] = "2026-09-21T00:00:00Z"
            data["release_expires_at"] = "2027-09-21T00:00:00Z"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError, "approved pack signature verification failed"
            ):
                validate_manifest(manifest, registry)

            data["signature"] = {
                "algorithm": "ed25519",
                "key_id": "release-key-1",
                "value": "fixture-signature",
            }
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError, "requires signature format"
            ):
                validate_manifest(manifest, registry)

    def test_approved_pack_with_trusted_ed25519_signature_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)

            private = Ed25519PrivateKey.from_private_bytes(bytes([9]) * 32)
            public = private.public_key().public_bytes(
                encoding=serialization.Encoding.Raw,
                format=serialization.PublicFormat.Raw,
            ).hex()
            key_id = key_id_for_ed25519_public_key(public)

            policy = root / "policy"
            policy.mkdir(exist_ok=True)
            (policy / "trusted_pack_keys.json").write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "state": "active",
                        "keys": {
                            key_id: {
                                "algorithm": "ed25519",
                                "public_key": public,
                                "status": "active",
                                "min_release_sequence": 1,
                                "max_release_sequence": None,
                            }
                        },
                        "roles": {
                            "content-pack-release": {
                                "threshold": 1,
                                "key_ids": [key_id],
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )

            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["review_status"] = "approved"
            data["release_sequence"] = 1
            data["release_issued_at"] = "2026-09-21T00:00:00Z"
            data["release_expires_at"] = "2027-09-21T00:00:00Z"
            data["signature"] = {
                "format": "aaris-pack-signature-v1",
                "role": "content-pack-release",
                "signatures": [],
            }
            data["signature"]["signatures"].append(
                {
                    "algorithm": "ed25519",
                    "key_id": key_id,
                    "value": private.sign(
                        canonical_manifest_payload(data)
                    ).hex(),
                }
            )
            manifest.write_text(json.dumps(data), encoding="utf-8")
            validate_manifest(manifest, registry)

            backup_path = root / "policy" / "source_backups.json"
            backup_data = json.loads(backup_path.read_text(encoding="utf-8"))
            backup_data["backups"][0].update(
                {
                    "status": "pending",
                    "provider": None,
                    "storage_class": None,
                    "verified_at": None,
                    "verification_method": None,
                }
            )
            backup_path.write_text(json.dumps(backup_data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError, "source durability check failed"
            ):
                validate_manifest(manifest, registry)


    def test_attribution_required_pack_requires_notice(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            registry_data = json.loads(registry.read_text(encoding="utf-8"))
            registry_data["sources"][0]["attribution_required"] = True
            registry.write_text(json.dumps(registry_data), encoding="utf-8")
            with self.assertRaises(PackGateError):
                validate_manifest(manifest, registry)

    def test_attribution_notice_hash_is_verified(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            registry_data = json.loads(registry.read_text(encoding="utf-8"))
            registry_data["sources"][0]["attribution_required"] = True
            registry.write_text(json.dumps(registry_data), encoding="utf-8")

            notice = root / "content-packs" / "quran-example" / "1.0" / "NOTICE.txt"
            notice.write_text("required attribution", encoding="utf-8")
            manifest_data = json.loads(manifest.read_text(encoding="utf-8"))
            manifest_data["notice_path"] = "content-packs/quran-example/1.0/NOTICE.txt"
            manifest_data["notice_sha256"] = hashlib.sha256(notice.read_bytes()).hexdigest()
            manifest.write_text(json.dumps(manifest_data), encoding="utf-8")
            validate_manifest(manifest, registry)

            notice.write_text("tampered attribution", encoding="utf-8")
            with self.assertRaisesRegex(PackGateError, "notice_sha256 mismatch"):
                validate_manifest(manifest, registry)

    def test_notice_metadata_must_be_paired_even_when_not_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["notice_path"] = "content-packs/quran-example/1.0/NOTICE.txt"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError,
                "notice_path and notice_sha256 must be provided together",
            ):
                validate_manifest(manifest, registry)

    def test_attribution_notice_must_live_with_manifest_pack(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            registry_data = json.loads(registry.read_text(encoding="utf-8"))
            registry_data["sources"][0]["attribution_required"] = True
            registry.write_text(json.dumps(registry_data), encoding="utf-8")

            notice = root / "content-packs" / "shared" / "NOTICE.txt"
            notice.parent.mkdir(parents=True)
            notice.write_text("required attribution", encoding="utf-8")
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["notice_path"] = "content-packs/shared/NOTICE.txt"
            data["notice_sha256"] = hashlib.sha256(notice.read_bytes()).hexdigest()
            manifest.write_text(json.dumps(data), encoding="utf-8")

            with self.assertRaisesRegex(
                PackGateError,
                "notice_path must resolve inside manifest pack directory",
            ):
                validate_manifest(manifest, registry)

    def test_runtime_artifact_cannot_borrow_another_pack(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, built = self._fixture(root)
            other = root / "content-packs" / "other-pack" / "1.0" / "content.sqlite"
            other.parent.mkdir(parents=True)
            other.write_bytes(built.read_bytes())
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["artifact_path"] = "content-packs/other-pack/1.0/content.sqlite"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError,
                "artifact_path must resolve inside manifest pack directory",
            ):
                validate_manifest(manifest, registry)

    def test_runtime_artifact_symlink_cannot_borrow_another_pack(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, built = self._fixture(root)
            other = root / "content-packs" / "other-pack" / "1.0" / "content.sqlite"
            other.parent.mkdir(parents=True)
            other.write_bytes(built.read_bytes())
            built.unlink()
            built.symlink_to(other)
            with self.assertRaisesRegex(
                PackGateError,
                "artifact_path must resolve inside manifest pack directory",
            ):
                validate_manifest(manifest, registry)

    def test_attribution_notice_symlink_cannot_borrow_another_pack(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            registry_data = json.loads(registry.read_text(encoding="utf-8"))
            registry_data["sources"][0]["attribution_required"] = True
            registry.write_text(json.dumps(registry_data), encoding="utf-8")

            other = root / "content-packs" / "other-pack" / "1.0" / "NOTICE.txt"
            other.parent.mkdir(parents=True)
            other.write_text("required attribution", encoding="utf-8")
            local_notice = manifest.parent / "NOTICE.txt"
            local_notice.symlink_to(other)

            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["notice_path"] = str(local_notice.relative_to(root))
            data["notice_sha256"] = hashlib.sha256(other.read_bytes()).hexdigest()
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError,
                "notice_path must resolve inside manifest pack directory",
            ):
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

    def _add_latest_version_requirement(self, registry: Path) -> str:
        data = json.loads(registry.read_text(encoding="utf-8"))
        licence_sha = "a" * 64
        data["sources"][0]["licence_sha256"] = licence_sha
        data["sources"][0]["release_requirements"] = {
            "latest_upstream_version_required": True,
            "version_check_url": "https://example.invalid/versions",
            "historical_snapshot_retention_status": "verified-allowed",
        }
        registry.write_text(json.dumps(data), encoding="utf-8")
        return licence_sha

    def _activate_test_release_key(self, root: Path, private: Ed25519PrivateKey) -> str:
        public = private.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        ).hex()
        key_id = key_id_for_ed25519_public_key(public)
        policy = root / "policy"
        policy.mkdir(exist_ok=True)
        (policy / "trusted_pack_keys.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "state": "active",
                    "keys": {
                        key_id: {
                            "algorithm": "ed25519",
                            "public_key": public,
                            "status": "active",
                            "min_release_sequence": 1,
                            "max_release_sequence": None,
                        }
                    },
                    "roles": {
                        "content-pack-release": {
                            "threshold": 1,
                            "key_ids": [key_id],
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        return key_id

    def test_pack_rejects_source_with_unresolved_historical_retention(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            data = json.loads(registry.read_text(encoding="utf-8"))
            data["sources"][0]["release_requirements"] = {
                "latest_upstream_version_required": True,
                "version_check_url": "https://example.invalid/versions",
                "historical_snapshot_retention_status": "unresolved",
            }
            registry.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError, "verified historical snapshot retention permission"
            ):
                validate_manifest(manifest, registry)


    def test_latest_version_requirement_does_not_expire_candidate_builds(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            self._add_latest_version_requirement(registry)
            validate_manifest(manifest, registry)

    def test_latest_version_requirement_blocks_approved_pack_without_review(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            self._add_latest_version_requirement(registry)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["review_status"] = "approved"
            data["release_sequence"] = 1
            data["release_issued_at"] = "2026-09-21T00:00:00Z"
            data["release_expires_at"] = "2027-09-21T00:00:00Z"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(PackGateError, "source_release_review"):
                validate_manifest(manifest, registry)

    def test_latest_version_review_is_bound_into_signed_approved_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            licence_sha = self._add_latest_version_requirement(registry)
            private = Ed25519PrivateKey.from_private_bytes(bytes([11]) * 32)
            key_id = self._activate_test_release_key(root, private)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["review_status"] = "approved"
            data["release_sequence"] = 1
            data["release_issued_at"] = "2026-09-21T00:00:00Z"
            data["release_expires_at"] = "2027-09-21T00:00:00Z"
            data["source_release_review"] = {
                "source_id": "quran.example.v1",
                "source_version": "1.0",
                "observed_upstream_version": "1.0",
                "version_check_url": "https://example.invalid/versions",
                "checked_at": "2026-09-21T00:00:00Z",
                "licence_sha256": licence_sha,
                "latest_upstream_version_confirmed": True,
            }
            data["signature"] = {
                "format": "aaris-pack-signature-v1",
                "role": "content-pack-release",
                "signatures": [],
            }
            data["signature"]["signatures"].append(
                {
                    "algorithm": "ed25519",
                    "key_id": key_id,
                    "value": private.sign(canonical_manifest_payload(data)).hex(),
                }
            )
            manifest.write_text(json.dumps(data), encoding="utf-8")
            validate_manifest(manifest, registry)

            data["source_release_review"]["observed_upstream_version"] = "1.0.1"
            data["signature"]["signatures"][0]["value"] = private.sign(
                canonical_manifest_payload(data)
            ).hex()
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError, "source_release_review does not match Source Vault"
            ):
                validate_manifest(manifest, registry)


if __name__ == "__main__":
    unittest.main()
