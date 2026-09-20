from __future__ import annotations

import base64
import json
from pathlib import Path
import tempfile
import unittest

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from tools.pack_signing import (
    DOMAIN_SEPARATOR,
    PAYLOAD_FORMAT,
    PackSignatureError,
    signature_payload,
    verify_ed25519_signature,
    verify_manifest_signature,
)


RFC8032_SECRET = bytes.fromhex(
    "9d61b19deffd5a60ba844af492ec2cc4"
    "4449c5697b326919703bac031cae7f60"
)
RFC8032_PUBLIC = bytes.fromhex(
    "d75a980182b10ab7d54bfed3c964073a"
    "0ee172f3daa62325af021a68f707511a"
)
RFC8032_EMPTY_SIGNATURE = bytes.fromhex(
    "e5564300c360ac729086e2cc806e828a"
    "84877f1eb8e5d974d873e06522490155"
    "5fb8821590a33bacc61e39701cf9b46b"
    "d25bf5f0595bbe24655141438e7a100b"
)


class PackSigningTests(unittest.TestCase):
    def _manifest(self) -> dict:
        return {
            "pack_id": "quran-core",
            "schema_version": 2,
            "content_version": "1.0.5",
            "review_status": "approved",
            "release_sequence": 1,
            "source_id": "quran.tanzil.uthmani.v1.1",
            "source_sha256": "a" * 64,
            "built_sha256": "b" * 64,
            "built_byte_size": 1234,
            "dependencies": [],
            "source_attribution": "Example — attribution preserved exactly",
            "signature": {"status": "unsigned"},
        }

    def _policy(self, root: Path, *, threshold: int = 1, status: str = "active") -> Path:
        path = root / "trusted_pack_keys.json"
        path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "signature_threshold": threshold,
                    "keys": [
                        {
                            "key_id": "rfc8032-test-key",
                            "algorithm": "ed25519",
                            "status": status,
                            "public_key_base64": base64.b64encode(
                                RFC8032_PUBLIC
                            ).decode("ascii"),
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        return path

    def _sign(self, manifest: dict) -> None:
        private = Ed25519PrivateKey.from_private_bytes(RFC8032_SECRET)
        signature = private.sign(signature_payload(manifest))
        manifest["signature"] = {
            "status": "signed",
            "payload_format": PAYLOAD_FORMAT,
            "signatures": [
                {
                    "algorithm": "ed25519",
                    "key_id": "rfc8032-test-key",
                    "value": base64.b64encode(signature).decode("ascii"),
                }
            ],
        }

    def test_rfc8032_test_vector_verifies(self) -> None:
        self.assertTrue(
            verify_ed25519_signature(
                RFC8032_PUBLIC,
                RFC8032_EMPTY_SIGNATURE,
                b"",
            )
        )

    def test_manifest_signature_verifies_against_trusted_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            manifest = self._manifest()
            self._sign(manifest)
            keys = self._policy(Path(tmp))
            self.assertEqual(
                verify_manifest_signature(manifest, keys),
                ("rfc8032-test-key",),
            )

    def test_signed_payload_is_deterministic_and_excludes_signature_bytes(self) -> None:
        first = self._manifest()
        second = dict(reversed(list(first.items())))
        first_payload = signature_payload(first)
        second_payload = signature_payload(second)
        self.assertTrue(first_payload.startswith(DOMAIN_SEPARATOR))
        self.assertEqual(first_payload, second_payload)

        self._sign(first)
        self.assertEqual(signature_payload(first), first_payload)

    def test_tampering_signed_field_breaks_verification(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            manifest = self._manifest()
            self._sign(manifest)
            keys = self._policy(Path(tmp))
            manifest["built_sha256"] = "c" * 64
            with self.assertRaisesRegex(
                PackSignatureError, "trusted signature threshold not met"
            ):
                verify_manifest_signature(manifest, keys)

    def test_revoked_key_never_counts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            manifest = self._manifest()
            self._sign(manifest)
            keys = self._policy(Path(tmp), status="revoked")
            with self.assertRaisesRegex(
                PackSignatureError, "trusted signature threshold not met"
            ):
                verify_manifest_signature(manifest, keys)

    def test_retired_key_can_verify_historical_pack(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            manifest = self._manifest()
            self._sign(manifest)
            keys = self._policy(Path(tmp), status="retired")
            self.assertEqual(
                verify_manifest_signature(manifest, keys),
                ("rfc8032-test-key",),
            )

    def test_threshold_is_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            manifest = self._manifest()
            self._sign(manifest)
            keys = self._policy(Path(tmp), threshold=2)
            with self.assertRaisesRegex(
                PackSignatureError, "trusted signature threshold not met: 1/2"
            ):
                verify_manifest_signature(manifest, keys)

    def test_release_sequence_is_mandatory_for_approved_pack(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            manifest = self._manifest()
            manifest.pop("release_sequence")
            self._sign(manifest)
            keys = self._policy(Path(tmp))
            with self.assertRaisesRegex(PackSignatureError, "release_sequence"):
                verify_manifest_signature(manifest, keys)

    def test_floats_are_rejected_from_signed_payload(self) -> None:
        manifest = self._manifest()
        manifest["unsafe_float"] = 1.5
        with self.assertRaisesRegex(PackSignatureError, "floats are forbidden"):
            signature_payload(manifest)


if __name__ == "__main__":
    unittest.main()
