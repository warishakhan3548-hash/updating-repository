import base64
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from tools.pack_gate import PackGateError, validate_manifest
from tools.pack_signing import PAYLOAD_FORMAT, signature_payload


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

    def test_approved_pack_requires_verified_signature_not_just_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _ = self._fixture(Path(tmp))
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["review_status"] = "approved"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError, "approved pack requires signature"
            ):
                validate_manifest(manifest, registry)

            data["signature"] = {
                "algorithm": "ed25519",
                "key_id": "release-key-1",
                "value": "fixture-signature",
            }
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError,
                "approved packs are disabled until cryptographic signature verification",
            ):
                validate_manifest(manifest, registry)


    @staticmethod
    def _install_test_release_key(root: Path, public_key: bytes) -> Path:
        policy_dir = root / "policy"
        policy_dir.mkdir(parents=True, exist_ok=True)
        path = policy_dir / "trusted_pack_keys.json"
        path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "signature_threshold": 1,
                    "keys": [
                        {
                            "key_id": "release-key-1",
                            "algorithm": "ed25519",
                            "status": "active",
                            "min_release_sequence": 1,
                            "max_release_sequence": None,
                            "public_key_base64": base64.b64encode(public_key).decode(
                                "ascii"
                            ),
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        return path

    def test_approved_pack_requires_verified_signature_not_just_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["review_status"] = "approved"
            data["release_sequence"] = 1
            data["signature"] = {
                "status": "signed",
                "payload_format": PAYLOAD_FORMAT,
                "signatures": [
                    {
                        "algorithm": "ed25519",
                        "key_id": "release-key-1",
                        "value": base64.b64encode(b"not-a-real-signature").decode(
                            "ascii"
                        ),
                    }
                ],
            }
            self._install_test_release_key(
                root,
                bytes.fromhex(
                    "d75a980182b10ab7d54bfed3c964073a"
                    "0ee172f3daa62325af021a68f707511a"
                ),
            )
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                PackGateError, "trusted signature threshold not met"
            ):
                validate_manifest(manifest, registry)

    def test_approved_pack_passes_only_with_real_trusted_signature(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _ = self._fixture(root)
            private = Ed25519PrivateKey.from_private_bytes(
                bytes.fromhex(
                    "9d61b19deffd5a60ba844af492ec2cc4"
                    "4449c5697b326919703bac031cae7f60"
                )
            )
            self._install_test_release_key(
                root,
                private.public_key().public_bytes_raw(),
            )

            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["review_status"] = "approved"
            data["release_sequence"] = 1
            signed = private.sign(signature_payload(data))
            data["signature"] = {
                "status": "signed",
                "payload_format": PAYLOAD_FORMAT,
                "signatures": [
                    {
                        "algorithm": "ed25519",
                        "key_id": "release-key-1",
                        "value": base64.b64encode(signed).decode("ascii"),
                    }
                ],
            }
            manifest.write_text(json.dumps(data), encoding="utf-8")
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


if __name__ == "__main__":
    unittest.main()
