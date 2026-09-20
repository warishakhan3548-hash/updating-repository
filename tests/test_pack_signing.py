from __future__ import annotations

import base64
import json
from pathlib import Path
import tempfile
import unittest

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from tools.pack_signing import (
    ALGORITHM,
    DOMAIN_SEPARATOR,
    PAYLOAD_FORMAT,
    SIGNATURE_ENCODING,
    PackSignatureError,
    public_key_id,
    signature_payload,
    validate_trusted_key_policy,
    verify_manifest_signature,
)


class PackSigningTests(unittest.TestCase):
    def _manifest(self) -> dict:
        return {
            "pack_id": "quran-core",
            "schema_version": 3,
            "content_version": "1.1.1",
            "content_schema_version": 1,
            "review_status": "approved",
            "release_sequence": 1,
            "source_id": "quran.tanzil.uthmani.v1.1",
            "source_name": "Tanzil Quran Text",
            "source_version": "1.1",
            "source_vault_path": "source-vault/quran/tanzil/1.1/quran.txt",
            "source_sha256": "a" * 64,
            "source_licence_sha256": "b" * 64,
            "source_provenance_sha256": "c" * 64,
            "licence": "example",
            "importer_version": "fixture-1",
            "artifact_path": "content-packs/quran-core/1.1.1/content.sqlite",
            "record_count": 6236,
            "built_sha256": "d" * 64,
            "built_byte_size": 1234,
            "notice_sha256": "e" * 64,
            "dependencies": [],
            "canonical": {
                "canonical_id": "quran-core",
                "canonical_version": "1.0.0",
                "generator_version": "fixture-1",
                "manifest_path": "canonical/quran-core/1.0.0/manifest.json",
                "manifest_sha256": "f" * 64,
                "artifact_path": "canonical/quran-core/1.0.0/ayahs.jsonl",
                "artifact_sha256": "1" * 64,
                "artifact_byte_size": 999,
                "record_count": 6236,
            },
            "build_toolchain": {
                "python_implementation": "CPython",
                "python_version": "3.13.15",
                "sqlite_version": "3.50.4",
            },
            "byte_reproducibility_scope": "same pinned toolchain",
            "source_attribution": "Tanzil Project — exact source notice",
            "signature": {"status": "unsigned"},
        }

    def _key(self):
        private = ec.generate_private_key(ec.SECP256R1())
        public = private.public_key()
        der = public.public_bytes(
            serialization.Encoding.DER,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        return (
            private,
            public_key_id(public),
            base64.b64encode(der).decode("ascii"),
        )

    def _policy(
        self,
        root: Path,
        key_id: str,
        public_b64: str,
        *,
        threshold: int = 1,
        status: str = "active",
        allowed_pack_ids=None,
        min_release_sequence=None,
        max_release_sequence=None,
    ) -> Path:
        entry = {
            "key_id": key_id,
            "algorithm": ALGORITHM,
            "status": status,
            "public_key_spki_base64": public_b64,
        }
        if allowed_pack_ids is not None:
            entry["allowed_pack_ids"] = allowed_pack_ids
        if min_release_sequence is not None:
            entry["min_release_sequence"] = min_release_sequence
        if max_release_sequence is not None:
            entry["max_release_sequence"] = max_release_sequence
        path = root / "trusted_pack_keys.json"
        path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "signature_threshold": threshold,
                    "keys": [entry],
                }
            ),
            encoding="utf-8",
        )
        return path

    def _sign(self, manifest: dict, private, key_id: str) -> None:
        signature = private.sign(
            signature_payload(manifest),
            ec.ECDSA(hashes.SHA256()),
        )
        manifest["signature"] = {
            "status": "signed",
            "payload_format": PAYLOAD_FORMAT,
            "signatures": [
                {
                    "algorithm": ALGORITHM,
                    "encoding": SIGNATURE_ENCODING,
                    "key_id": key_id,
                    "value": base64.b64encode(signature).decode("ascii"),
                }
            ],
        }

    def test_manifest_signature_verifies_against_trusted_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, key_id, public_b64 = self._key()
            manifest = self._manifest()
            self._sign(manifest, private, key_id)
            keys = self._policy(
                root,
                key_id,
                public_b64,
                allowed_pack_ids=["quran-core"],
            )
            self.assertEqual(
                verify_manifest_signature(manifest, keys),
                (key_id,),
            )

    def test_signed_payload_is_deterministic_and_excludes_signature_bytes(self) -> None:
        first = self._manifest()
        second = dict(reversed(list(first.items())))
        first_payload = signature_payload(first)
        self.assertTrue(first_payload.startswith(DOMAIN_SEPARATOR))
        self.assertEqual(first_payload, signature_payload(second))

        private, key_id, _ = self._key()
        self._sign(first, private, key_id)
        self.assertEqual(signature_payload(first), first_payload)

    def test_schema_v3_canonical_binding_is_covered(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, key_id, public_b64 = self._key()
            manifest = self._manifest()
            self._sign(manifest, private, key_id)
            keys = self._policy(root, key_id, public_b64)
            manifest["canonical"]["artifact_sha256"] = "2" * 64
            with self.assertRaisesRegex(
                PackSignatureError,
                "threshold not met",
            ):
                verify_manifest_signature(manifest, keys)

    def test_revoked_key_never_counts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, key_id, public_b64 = self._key()
            manifest = self._manifest()
            self._sign(manifest, private, key_id)
            keys = self._policy(
                root,
                key_id,
                public_b64,
                status="revoked",
            )
            with self.assertRaisesRegex(
                PackSignatureError,
                "threshold not met",
            ):
                verify_manifest_signature(manifest, keys)

    def test_retired_key_can_verify_historical_pack_inside_sequence_window(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, key_id, public_b64 = self._key()
            manifest = self._manifest()
            self._sign(manifest, private, key_id)
            keys = self._policy(
                root,
                key_id,
                public_b64,
                status="retired",
                max_release_sequence=1,
            )
            self.assertEqual(
                verify_manifest_signature(manifest, keys),
                (key_id,),
            )

    def test_key_scope_and_release_window_are_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, key_id, public_b64 = self._key()
            manifest = self._manifest()
            self._sign(manifest, private, key_id)
            keys = self._policy(
                root,
                key_id,
                public_b64,
                allowed_pack_ids=["hadith-core"],
                min_release_sequence=2,
            )
            with self.assertRaisesRegex(
                PackSignatureError,
                "threshold not met",
            ):
                verify_manifest_signature(manifest, keys)

    def test_threshold_is_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, key_id, public_b64 = self._key()
            manifest = self._manifest()
            self._sign(manifest, private, key_id)
            keys = self._policy(root, key_id, public_b64, threshold=2)
            with self.assertRaisesRegex(PackSignatureError, "1/2"):
                verify_manifest_signature(manifest, keys)

    def test_public_key_fingerprint_must_match_key_id(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, key_id, _ = self._key()
            _, _, different_public_b64 = self._key()
            keys = self._policy(
                root,
                key_id,
                different_public_b64,
            )
            with self.assertRaisesRegex(
                PackSignatureError,
                "fingerprint",
            ):
                validate_trusted_key_policy(keys)

    def test_release_sequence_is_mandatory_for_approved_pack(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private, key_id, public_b64 = self._key()
            manifest = self._manifest()
            manifest.pop("release_sequence")
            self._sign(manifest, private, key_id)
            keys = self._policy(root, key_id, public_b64)
            with self.assertRaisesRegex(
                PackSignatureError,
                "release_sequence",
            ):
                verify_manifest_signature(manifest, keys)

    def test_floats_and_unpaired_surrogates_are_rejected(self) -> None:
        manifest = self._manifest()
        manifest["unsafe_float"] = 1.5
        with self.assertRaisesRegex(
            PackSignatureError,
            "floats are forbidden",
        ):
            signature_payload(manifest)
        manifest.pop("unsafe_float")
        manifest["unsafe_string"] = "x\ud800"
        with self.assertRaisesRegex(PackSignatureError, "surrogate"):
            signature_payload(manifest)


if __name__ == "__main__":
    unittest.main()
