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
    loads_strict_json,
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
                        item[0]: {
                            "algorithm": "ed25519",
                            "public_key": item[1],
                            "status": item[2] if len(item) > 2 else "active",
                            "min_release_sequence": item[3] if len(item) > 3 else 1,
                            "max_release_sequence": item[4] if len(item) > 4 else None,
                        }
                        for item in keys
                    },
                    "roles": {
                        "content-pack-release": {
                            "threshold": threshold,
                            "key_ids": [
                                item[0] for item in keys
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

    def test_non_ascii_object_key_is_rejected_from_signed_payload(self):
        manifest = self._manifest()
        manifest["مفتاح"] = "value"
        with self.assertRaisesRegex(
            PackSignatureError, "non-ASCII JSON object key"
        ):
            canonical_manifest_payload(manifest)

    def test_unicode_string_values_are_preserved_in_signed_payload(self):
        manifest = self._manifest()
        manifest["source_attribution"] = "مصدر موثوق"
        payload = canonical_manifest_payload(manifest)
        self.assertIn("مصدر موثوق".encode("utf-8"), payload)

    def test_invalid_unicode_surrogate_is_rejected_cleanly(self):
        manifest = self._manifest()
        manifest["source_attribution"] = "\ud800"
        with self.assertRaisesRegex(
            PackSignatureError, "invalid Unicode scalar value"
        ):
            canonical_manifest_payload(manifest)

    def test_large_integer_is_rejected_from_signed_payload(self):
        manifest = self._manifest()
        manifest["sequence"] = 9_007_199_254_740_992
        with self.assertRaisesRegex(
            PackSignatureError, "cross-runtime safe range"
        ):
            canonical_manifest_payload(manifest)

    def test_strict_json_rejects_duplicate_keys_and_nonstandard_constants(self):
        with self.assertRaisesRegex(PackSignatureError, "duplicate JSON object key"):
            loads_strict_json('{"pack_id":"first","pack_id":"second"}')
        with self.assertRaisesRegex(PackSignatureError, "non-standard JSON constant"):
            loads_strict_json('{"score":NaN}')

    def test_key_policy_rejects_duplicate_json_object_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            keyring = Path(tmp) / "trusted_pack_keys.json"
            keyring.write_text(
                '{"schema_version":1,"state":"bootstrap-required",'
                '"state":"active","keys":{},"roles":{"content-pack-release":'
                '{"threshold":1,"key_ids":[]}}}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                PackSignatureError, "duplicate JSON object key"
            ):
                validate_trusted_key_policy(keyring)

    def test_retired_key_verifies_only_its_historical_sequence_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, public, key_id = self._key(12)
            keyring = self._write_keyring(
                root,
                [(key_id, public, "retired", 2, 4)],
                state="active",
            )

            historical = self._manifest()
            historical["release_sequence"] = 4
            self._sign(historical, private, key_id)
            self.assertEqual(
                1,
                verify_approved_manifest(historical, keyring),
            )

            future = self._manifest()
            future["release_sequence"] = 5
            self._sign(future, private, key_id)
            with self.assertRaisesRegex(
                PackSignatureError, "release-sequence window"
            ):
                verify_approved_manifest(future, keyring)

    def test_revoked_key_never_verifies(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, public, key_id = self._key(13)
            keyring = self._write_keyring(
                root,
                [(key_id, public, "revoked", 1, None)],
                state="bootstrap-required",
            )
            manifest = self._manifest()
            self._sign(manifest, private, key_id)

            # Structural policy validation preserves revoked key history.
            validate_trusted_key_policy(keyring)
            policy = json.loads(keyring.read_text(encoding="utf-8"))
            policy["state"] = "active"
            _, active_public, active_id = self._key(14)
            policy["keys"][active_id] = {
                "algorithm": "ed25519",
                "public_key": active_public,
                "status": "active",
                "min_release_sequence": 1,
                "max_release_sequence": None,
            }
            policy["roles"]["content-pack-release"]["key_ids"].append(active_id)
            keyring.write_text(json.dumps(policy), encoding="utf-8")

            with self.assertRaisesRegex(
                PackSignatureError, "revoked"
            ):
                verify_approved_manifest(manifest, keyring)

    def test_active_policy_threshold_must_be_satisfiable_by_active_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, active_public, active_id = self._key(15)
            _, retired_public, retired_id = self._key(16)
            keyring = self._write_keyring(
                root,
                [
                    (active_id, active_public, "active", 1, None),
                    (retired_id, retired_public, "retired", 1, 2),
                ],
                threshold=2,
                state="active",
            )
            with self.assertRaisesRegex(
                PackSignatureError, "active authorized key count"
            ):
                validate_trusted_key_policy(keyring)

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
                                "status": "active",
                                "min_release_sequence": 1,
                                "max_release_sequence": None,
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
