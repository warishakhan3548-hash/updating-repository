import copy
import json
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from tools.pack_signatures import (
    DOMAIN_SEPARATOR,
    MAX_SAFE_INTEGER,
    SIGNATURE_FORMAT,
    PackSignatureError,
    canonical_manifest_payload,
    key_id_for_ed25519_public_key,
    validate_trusted_key_policy,
    verify_approved_manifest,
)


class PackSignatureTests(unittest.TestCase):
    def _key(self, seed: int):
        private = Ed25519PrivateKey.from_private_bytes(
            bytes([seed]) * 32
        )
        public = private.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        ).hex()
        return (
            private,
            public,
            key_id_for_ed25519_public_key(public),
        )

    def _manifest(self):
        return {
            "pack_id": "quran-core",
            "schema_version": 3,
            "content_version": "1.2.3",
            "review_status": "approved",
            "release_sequence": 1,
            "built_sha256": "ab" * 32,
            "built_byte_size": 123,
            "dependencies": [],
            "signature": {
                "format": SIGNATURE_FORMAT,
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
                    "schema_version": 2,
                    "state": state,
                    "keys": {
                        key_id: {
                            "algorithm": "ed25519",
                            "public_key": public,
                            "status": status,
                            "min_release_sequence": minimum,
                            "max_release_sequence": maximum,
                        }
                        for (
                            key_id,
                            public,
                            status,
                            minimum,
                            maximum,
                        ) in keys
                    },
                    "roles": {
                        "content-pack-release": {
                            "threshold": threshold,
                            "key_ids": [
                                key_id
                                for (
                                    key_id,
                                    _,
                                    _,
                                    _,
                                    _,
                                ) in keys
                            ],
                        }
                    },
                },
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        return keyring

    def _active(self, seed: int, *, minimum: int = 1):
        private, public, key_id = self._key(seed)
        return (
            private,
            (
                key_id,
                public,
                "active",
                minimum,
                None,
            ),
        )

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
            p1, k1 = self._active(1)
            p2, k2 = self._active(2)
            keyring = self._write_keyring(
                root,
                [k1, k2],
                threshold=2,
            )
            manifest = self._manifest()
            self._sign(manifest, p1, k1[0])
            self._sign(manifest, p2, k2[0])
            self.assertEqual(
                2,
                verify_approved_manifest(
                    manifest,
                    keyring,
                ),
            )

    def test_signed_payload_is_domain_separated_and_signature_excluded(self):
        manifest = self._manifest()
        before = canonical_manifest_payload(manifest)
        self.assertTrue(
            before.startswith(DOMAIN_SEPARATOR)
        )
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

    def test_manifest_tamper_after_signing_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, key = self._active(3)
            keyring = self._write_keyring(root, [key])
            manifest = self._manifest()
            self._sign(
                manifest,
                private,
                key[0],
            )
            manifest["built_byte_size"] = 124
            with self.assertRaisesRegex(
                PackSignatureError,
                "invalid Ed25519",
            ):
                verify_approved_manifest(
                    manifest,
                    keyring,
                )

    def test_release_sequence_tamper_after_signing_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, key = self._active(4)
            keyring = self._write_keyring(root, [key])
            manifest = self._manifest()
            self._sign(manifest, private, key[0])
            manifest["release_sequence"] = 2
            with self.assertRaisesRegex(
                PackSignatureError,
                "invalid Ed25519",
            ):
                verify_approved_manifest(
                    manifest,
                    keyring,
                )

    def test_release_sequence_is_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, key = self._active(5)
            keyring = self._write_keyring(root, [key])
            manifest = self._manifest()
            manifest.pop("release_sequence")
            with self.assertRaisesRegex(
                PackSignatureError,
                "release_sequence",
            ):
                verify_approved_manifest(
                    manifest,
                    keyring,
                )

    def test_unsafe_integer_is_rejected_before_signing(self):
        manifest = self._manifest()
        manifest["release_sequence"] = (
            MAX_SAFE_INTEGER + 1
        )
        with self.assertRaisesRegex(
            PackSignatureError,
            "safe range",
        ):
            canonical_manifest_payload(manifest)

    def test_float_in_signed_payload_is_rejected(self):
        manifest = self._manifest()
        manifest["score"] = 0.5
        with self.assertRaisesRegex(
            PackSignatureError,
            "floating-point",
        ):
            canonical_manifest_payload(manifest)

    def test_invalid_unicode_scalar_is_rejected(self):
        manifest = self._manifest()
        manifest["note"] = "\ud800"
        with self.assertRaisesRegex(
            PackSignatureError,
            "Unicode scalar",
        ):
            canonical_manifest_payload(manifest)

    def test_unconfigured_keyring_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, key = self._active(6)
            keyring = self._write_keyring(
                root,
                [key],
                state="bootstrap-required",
            )
            manifest = self._manifest()
            self._sign(
                manifest,
                private,
                key[0],
            )
            with self.assertRaisesRegex(
                PackSignatureError,
                "not active",
            ):
                verify_approved_manifest(
                    manifest,
                    keyring,
                )

    def test_duplicate_signature_key_cannot_satisfy_threshold(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            p1, k1 = self._active(7)
            _, k2 = self._active(8)
            keyring = self._write_keyring(
                root,
                [k1, k2],
                threshold=2,
            )
            manifest = self._manifest()
            self._sign(manifest, p1, k1[0])
            manifest["signature"]["signatures"].append(
                copy.deepcopy(
                    manifest["signature"][
                        "signatures"
                    ][0]
                )
            )
            with self.assertRaisesRegex(
                PackSignatureError,
                "duplicate",
            ):
                verify_approved_manifest(
                    manifest,
                    keyring,
                )

    def test_unauthorized_signature_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, trusted = self._active(9)
            attacker, attacker_key = self._active(10)
            keyring = self._write_keyring(
                root,
                [trusted],
            )
            manifest = self._manifest()
            self._sign(
                manifest,
                attacker,
                attacker_key[0],
            )
            with self.assertRaisesRegex(
                PackSignatureError,
                "not authorized",
            ):
                verify_approved_manifest(
                    manifest,
                    keyring,
                )

    def test_revoked_key_never_verifies(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, public, key_id = self._key(11)
            key = (
                key_id,
                public,
                "revoked",
                1,
                None,
            )
            keyring = self._write_keyring(root, [key])
            manifest = self._manifest()
            self._sign(manifest, private, key_id)
            with self.assertRaisesRegex(
                PackSignatureError,
                "revoked",
            ):
                verify_approved_manifest(
                    manifest,
                    keyring,
                )

    def test_retired_key_verifies_only_bounded_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, public, key_id = self._key(12)
            key = (
                key_id,
                public,
                "retired",
                1,
                5,
            )
            keyring = self._write_keyring(root, [key])

            historical = self._manifest()
            historical["release_sequence"] = 5
            self._sign(
                historical,
                private,
                key_id,
            )
            self.assertEqual(
                1,
                verify_approved_manifest(
                    historical,
                    keyring,
                ),
            )

            future = self._manifest()
            future["release_sequence"] = 6
            self._sign(
                future,
                private,
                key_id,
            )
            with self.assertRaisesRegex(
                PackSignatureError,
                "exceeds key authorization",
            ):
                verify_approved_manifest(
                    future,
                    keyring,
                )

    def test_active_key_cannot_have_sequence_ceiling(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, public, key_id = self._key(13)
            keyring = self._write_keyring(
                root,
                [
                    (
                        key_id,
                        public,
                        "active",
                        1,
                        5,
                    )
                ],
            )
            with self.assertRaisesRegex(
                PackSignatureError,
                "active trusted key",
            ):
                validate_trusted_key_policy(keyring)

    def test_retired_key_requires_sequence_ceiling(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, public, key_id = self._key(14)
            keyring = self._write_keyring(
                root,
                [
                    (
                        key_id,
                        public,
                        "retired",
                        1,
                        None,
                    )
                ],
            )
            with self.assertRaisesRegex(
                PackSignatureError,
                "retired trusted key",
            ):
                validate_trusted_key_policy(keyring)

    def test_duplicate_policy_json_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "trusted_pack_keys.json"
            path.write_text(
                '{"schema_version":2,'
                '"state":"active",'
                '"state":"bootstrap-required",'
                '"keys":{},'
                '"roles":{"content-pack-release":'
                '{"threshold":1,"key_ids":[]}}}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                PackSignatureError,
                "duplicate JSON object key",
            ):
                validate_trusted_key_policy(path)

    def test_repository_bootstrap_policy_is_structurally_valid(self):
        root = Path(__file__).resolve().parents[1]
        keys, authorized, threshold = (
            validate_trusted_key_policy(
                root
                / "policy"
                / "trusted_pack_keys.json"
            )
        )
        self.assertEqual({}, keys)
        self.assertEqual(set(), authorized)
        self.assertEqual(1, threshold)

    def test_bootstrap_policy_still_rejects_bad_key_fingerprint(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, public, _ = self._key(15)
            keyring = root / "trusted_pack_keys.json"
            keyring.write_text(
                json.dumps(
                    {
                        "schema_version": 2,
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
                PackSignatureError,
                "trusted key id mismatch",
            ):
                validate_trusted_key_policy(keyring)


if __name__ == "__main__":
    unittest.main()
