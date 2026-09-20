from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from tools.pack_signatures import (
    PAYLOAD_VERSION,
    PackSignatureError,
    canonical_manifest_payload,
    canonical_json_bytes,
    ed25519_key_id,
    verify_manifest_signatures,
)


class PackSignatureTests(unittest.TestCase):
    def _public_hex(self, private_key: Ed25519PrivateKey) -> str:
        return private_key.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        ).hex()

    def _root(
        self,
        directory: Path,
        private_keys: list[Ed25519PrivateKey],
        *,
        threshold: int = 1,
        version: int = 2,
        revoked: set[int] | None = None,
    ) -> tuple[Path, list[str]]:
        revoked = revoked or set()
        keys = {}
        key_ids = []
        for index, private_key in enumerate(private_keys):
            public = self._public_hex(private_key)
            key_id = ed25519_key_id(public)
            key_ids.append(key_id)
            keys[key_id] = {
                "keytype": "ed25519",
                "scheme": "ed25519",
                "status": "revoked" if index in revoked else "active",
                "keyval": {"public": public},
            }

        path = directory / f"root-v{version}.json"
        path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "role": "content-pack-release",
                    "version": version,
                    "threshold": threshold,
                    "keys": keys,
                }
            ),
            encoding="utf-8",
        )
        return path, key_ids

    def _manifest(self) -> dict:
        return {
            "pack_id": "quran-example",
            "schema_version": 2,
            "content_version": "1.0.0",
            "review_status": "approved",
            "release_sequence": 1,
            "built_sha256": "0" * 64,
            "signature": {
                "payload_version": PAYLOAD_VERSION,
                "trust_root_version": 2,
                "signatures": [],
            },
        }

    def _sign(
        self,
        manifest: dict,
        private_key: Ed25519PrivateKey,
        key_id: str,
    ) -> None:
        value = private_key.sign(canonical_manifest_payload(manifest)).hex()
        manifest["signature"]["signatures"].append(
            {
                "algorithm": "ed25519",
                "key_id": key_id,
                "value": value,
            }
        )

    def test_valid_signature_meets_threshold(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            private_key = Ed25519PrivateKey.generate()
            root, key_ids = self._root(Path(tmp), [private_key])
            manifest = self._manifest()
            self._sign(manifest, private_key, key_ids[0])
            verify_manifest_signatures(manifest, root)

    def test_signed_field_tamper_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            private_key = Ed25519PrivateKey.generate()
            root, key_ids = self._root(Path(tmp), [private_key])
            manifest = self._manifest()
            self._sign(manifest, private_key, key_ids[0])
            manifest["content_version"] = "1.0.1"
            with self.assertRaisesRegex(
                PackSignatureError, "signature threshold not met"
            ):
                verify_manifest_signatures(manifest, root)

    def test_threshold_requires_distinct_trusted_keys(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            private_keys = [Ed25519PrivateKey.generate(), Ed25519PrivateKey.generate()]
            root, key_ids = self._root(Path(tmp), private_keys, threshold=2)
            manifest = self._manifest()
            self._sign(manifest, private_keys[0], key_ids[0])
            with self.assertRaisesRegex(
                PackSignatureError, "signature threshold not met"
            ):
                verify_manifest_signatures(manifest, root)

            self._sign(manifest, private_keys[1], key_ids[1])
            verify_manifest_signatures(manifest, root)

    def test_duplicate_key_id_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            private_key = Ed25519PrivateKey.generate()
            root, key_ids = self._root(Path(tmp), [private_key])
            manifest = self._manifest()
            self._sign(manifest, private_key, key_ids[0])
            manifest["signature"]["signatures"].append(
                dict(manifest["signature"]["signatures"][0])
            )
            with self.assertRaisesRegex(PackSignatureError, "duplicate signature"):
                verify_manifest_signatures(manifest, root)

    def test_revoked_key_does_not_count(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            active = Ed25519PrivateKey.generate()
            revoked = Ed25519PrivateKey.generate()
            root, key_ids = self._root(
                Path(tmp), [active, revoked], threshold=1, revoked={1}
            )
            manifest = self._manifest()
            self._sign(manifest, revoked, key_ids[1])
            with self.assertRaisesRegex(
                PackSignatureError, "signature threshold not met"
            ):
                verify_manifest_signatures(manifest, root)

    def test_key_id_is_bound_to_public_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            private_key = Ed25519PrivateKey.generate()
            root, key_ids = self._root(Path(tmp), [private_key])
            data = json.loads(root.read_text(encoding="utf-8"))
            key = data["keys"].pop(key_ids[0])
            data["keys"]["f" * 64] = key
            root.write_text(json.dumps(data), encoding="utf-8")
            manifest = self._manifest()
            manifest["signature"]["signatures"] = [
                {
                    "algorithm": "ed25519",
                    "key_id": "f" * 64,
                    "value": "0" * 128,
                }
            ]
            with self.assertRaisesRegex(
                PackSignatureError, "id does not match public key"
            ):
                verify_manifest_signatures(manifest, root)

    def test_canonical_payload_rejects_float_ambiguity(self) -> None:
        with self.assertRaisesRegex(PackSignatureError, "floats are not allowed"):
            canonical_json_bytes({"version": 1.0})


if __name__ == "__main__":
    unittest.main()
