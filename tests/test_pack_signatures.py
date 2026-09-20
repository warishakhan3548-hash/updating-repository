import copy
import json
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from tools.pack_signatures import (
    PackSignatureError,
    canonical_manifest_payload,
    key_id_for_ed25519_public_key,
    validate_trusted_key_policy,
    verify_approved_manifest,
)


class PackSignatureTests(unittest.TestCase):
    def _key(self, seed: int):
        private = Ed25519PrivateKey.from_private_bytes(bytes([seed]) * 32)
        public = private.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        ).hex()
        return private, public, key_id_for_ed25519_public_key(public)

    def _manifest(self):
        return {
            "pack_id": "quran-core",
            "schema_version": 2,
            "content_version": "1.2.3",
            "review_status": "approved",
            "release_sequence": 1,
            "built_sha256": "ab" * 32,
            "built_byte_size": 123,
            "dependencies": [],
            "signature": {
                "format": "aaris-pack-signature-v1",
                "role": "content-pack-release",
                "signatures": [],
            },
        }

    def _write_keyring(
        self,
        root: Path,
        keys,
        *,
        threshold=1,
        state="active",
    ):
        keyring = root / "trusted_pack_keys.json"
        keyring.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "state": state,
                    "keys": {
                        key_id: {
                            "algorithm": "ed25519",
                            "public_key": public,
                        }
                        for key_id, public in keys
                    },
                    "roles": {
                        "content-pack-release": {
                            "threshold": threshold,
                            "key_ids": [
                                key_id for key_id, _ in keys
                            ],
                        }
                    },
                },
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        return keyring

    def _sign(self, manifest, private, key_id):
        signature = private.sign(
            canonical_manifest_payload(manifest)
        ).hex()
        manifest["signature"]["signatures"].append(
            {
                "algorithm": "ed25519",
                "key_id": key_id,
                "value": signature,
            }
        )

    def test_valid_threshold_signature_verifies(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            p1, pub1, id1 = self._key(1)
            p2, pub2, id2 = self._key(2)
            keyring = self._write_keyring(
                root,
                [(id1, pub1), (id2, pub2)],
                threshold=2,
            )
            manifest = self._manifest()
            self._sign(manifest, p1, id1)
            self._sign(manifest, p2, id2)
            self.assertEqual(
                2,
                verify_approved_manifest(manifest, keyring),
            )

    def test_release_sequence_is_required_positive_and_signed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, public, key_id = self._key(11)
            keyring = self._write_keyring(
                root, [(key_id, public)]
            )

            missing = self._manifest()
            missing.pop("release_sequence")
            self._sign(missing, private, key_id)
            with self.assertRaisesRegex(
                PackSignatureError, "release_sequence"
            ):
                verify_approved_manifest(missing, keyring)

            zero = self._manifest()
            zero["release_sequence"] = 0
            self._sign(zero, private, key_id)
            with self.assertRaisesRegex(
                PackSignatureError, "release_sequence"
            ):
                verify_approved_manifest(zero, keyring)

            tampered = self._manifest()
            self._sign(tampered, private, key_id)
            tampered["release_sequence"] = 2
            with self.assertRaisesRegex(
                PackSignatureError, "invalid Ed25519"
            ):
                verify_approved_manifest(tampered, keyring)

    def test_manifest_tamper_after_signing_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, public, key_id = self._key(3)
            keyring = self._write_keyring(
                root, [(key_id, public)]
            )
            manifest = self._manifest()
            self._sign(manifest, private, key_id)
            manifest["built_byte_size"] = 124
            with self.assertRaisesRegex(
                PackSignatureError, "invalid Ed25519"
            ):
                verify_approved_manifest(manifest, keyring)

    def test_signature_block_is_not_part_of_signed_payload(self):
        manifest = self._manifest()
        before = canonical_manifest_payload(manifest)
        manifest["signature"]["signatures"].append(
            {
                "algorithm": "ed25519",
                "key_id": "x",
                "value": "y",
            }
        )
        self.assertEqual(
            before,
            canonical_manifest_payload(manifest),
        )

    def test_unconfigured_keyring_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, public, key_id = self._key(4)
            keyring = self._write_keyring(
                root,
                [(key_id, public)],
                state="bootstrap-required",
            )
            manifest = self._manifest()
            self._sign(manifest, private, key_id)
            with self.assertRaisesRegex(
                PackSignatureError, "not active"
            ):
                verify_approved_manifest(manifest, keyring)

    def test_duplicate_signature_key_cannot_satisfy_threshold(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            p1, pub1, id1 = self._key(5)
            _, pub2, id2 = self._key(6)
            keyring = self._write_keyring(
                root,
                [(id1, pub1), (id2, pub2)],
                threshold=2,
            )
            manifest = self._manifest()
            self._sign(manifest, p1, id1)
            manifest["signature"]["signatures"].append(
                copy.deepcopy(
                    manifest["signature"]["signatures"][0]
                )
            )
            with self.assertRaisesRegex(
                PackSignatureError, "duplicate"
            ):
                verify_approved_manifest(manifest, keyring)

    def test_unauthorized_signature_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, trusted_pub, trusted_id = self._key(7)
            attacker, _, attacker_id = self._key(8)
            keyring = self._write_keyring(
                root, [(trusted_id, trusted_pub)]
            )
            manifest = self._manifest()
            self._sign(manifest, attacker, attacker_id)
            with self.assertRaisesRegex(
                PackSignatureError, "not authorized"
            ):
                verify_approved_manifest(manifest, keyring)

    def test_float_in_signed_payload_is_rejected(self):
        manifest = self._manifest()
        manifest["score"] = 0.5
        with self.assertRaisesRegex(
            PackSignatureError, "floating-point"
        ):
            canonical_manifest_payload(manifest)

    def test_repository_bootstrap_policy_is_structurally_valid(self):
        root = Path(__file__).resolve().parents[1]
        keys, authorized, threshold = validate_trusted_key_policy(
            root / "policy" / "trusted_pack_keys.json"
        )
        self.assertEqual({}, keys)
        self.assertEqual(set(), authorized)
        self.assertEqual(1, threshold)

    def test_bootstrap_policy_still_rejects_bad_key_fingerprint(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, public, _ = self._key(10)
            keyring = root / "trusted_pack_keys.json"
            keyring.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "state": "bootstrap-required",
                        "keys": {
                            "0" * 64: {
                                "algorithm": "ed25519",
                                "public_key": public,
                            }
                        },
                        "roles": {
                            "content-pack-release": {
                                "threshold": 1,
                                "key_ids": [],
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                PackSignatureError, "trusted key id mismatch"
            ):
                validate_trusted_key_policy(keyring)


if __name__ == "__main__":
    unittest.main()
