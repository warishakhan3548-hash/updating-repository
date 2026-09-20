from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


PAYLOAD_VERSION = "aaris-pack-manifest-v1"
TRUST_ROLE = "content-pack-release"


class PackSignatureError(RuntimeError):
    pass


def _validate_json_value(value: Any, path: str = "$") -> None:
    if value is None or isinstance(value, (str, bool, int)):
        return
    if isinstance(value, float):
        raise PackSignatureError(f"{path}: floats are not allowed in signed metadata")
    if isinstance(value, list):
        for index, item in enumerate(value):
            _validate_json_value(item, f"{path}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise PackSignatureError(f"{path}: signed object keys must be strings")
            _validate_json_value(item, f"{path}.{key}")
        return
    raise PackSignatureError(
        f"{path}: unsupported signed metadata type {type(value).__name__}"
    )


def canonical_json_bytes(value: Any) -> bytes:
    _validate_json_value(value)
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def canonical_manifest_payload(manifest: dict[str, Any]) -> bytes:
    unsigned = dict(manifest)
    unsigned.pop("signature", None)
    return canonical_json_bytes(unsigned)


def _decode_hex(value: object, field: str, byte_length: int) -> bytes:
    if not isinstance(value, str) or len(value) != byte_length * 2:
        raise PackSignatureError(f"invalid {field}")
    try:
        decoded = bytes.fromhex(value)
    except ValueError as exc:
        raise PackSignatureError(f"invalid {field}") from exc
    if len(decoded) != byte_length:
        raise PackSignatureError(f"invalid {field}")
    return decoded


def ed25519_key_id(public_key_hex: str) -> str:
    public_key = _decode_hex(public_key_hex, "public key", 32)
    key_object = {
        "keytype": "ed25519",
        "scheme": "ed25519",
        "keyval": {"public": public_key.hex()},
    }
    return hashlib.sha256(canonical_json_bytes(key_object)).hexdigest()


def load_trust_root(path: Path) -> dict[str, Any]:
    try:
        root = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PackSignatureError(f"unable to load trusted key root: {path}") from exc

    if root.get("schema_version") != 1:
        raise PackSignatureError("unsupported trusted key root schema_version")
    if root.get("role") != TRUST_ROLE:
        raise PackSignatureError("trusted key root role mismatch")
    version = root.get("version")
    if not isinstance(version, int) or version < 1:
        raise PackSignatureError("trusted key root version must be a positive integer")
    threshold = root.get("threshold")
    if not isinstance(threshold, int) or threshold < 1:
        raise PackSignatureError("trusted key threshold must be a positive integer")
    keys = root.get("keys")
    if not isinstance(keys, dict):
        raise PackSignatureError("trusted key root keys must be an object")

    active_count = 0
    for key_id, key in keys.items():
        if not isinstance(key_id, str) or len(key_id) != 64:
            raise PackSignatureError("invalid trusted key id")
        if not isinstance(key, dict):
            raise PackSignatureError(f"trusted key {key_id} must be an object")
        if key.get("keytype") != "ed25519" or key.get("scheme") != "ed25519":
            raise PackSignatureError(
                f"trusted key {key_id} uses unsupported algorithm"
            )
        status = key.get("status")
        if status not in {"active", "revoked"}:
            raise PackSignatureError(f"trusted key {key_id} has invalid status")
        keyval = key.get("keyval")
        if not isinstance(keyval, dict):
            raise PackSignatureError(f"trusted key {key_id} lacks keyval")
        public = keyval.get("public")
        _decode_hex(public, f"public key for {key_id}", 32)
        if ed25519_key_id(public) != key_id:
            raise PackSignatureError(
                f"trusted key {key_id} id does not match public key"
            )
        if status == "active":
            active_count += 1

    if active_count < threshold:
        raise PackSignatureError(
            "trusted key root cannot satisfy its signature threshold"
        )
    return root


def verify_manifest_signatures(
    manifest: dict[str, Any], trust_root_path: Path
) -> None:
    signature = manifest.get("signature")
    if not isinstance(signature, dict):
        raise PackSignatureError("signature must be an object")
    if signature.get("payload_version") != PAYLOAD_VERSION:
        raise PackSignatureError("unsupported signature payload_version")
    trust_root_version = signature.get("trust_root_version")
    if not isinstance(trust_root_version, int) or trust_root_version < 1:
        raise PackSignatureError(
            "signature trust_root_version must be a positive integer"
        )
    signatures = signature.get("signatures")
    if not isinstance(signatures, list) or not signatures:
        raise PackSignatureError("approved pack requires at least one signature")

    release_sequence = manifest.get("release_sequence")
    if not isinstance(release_sequence, int) or release_sequence < 1:
        raise PackSignatureError("approved pack requires positive release_sequence")

    root = load_trust_root(trust_root_path)
    if root["version"] != trust_root_version:
        raise PackSignatureError(
            "manifest trust_root_version does not match trusted key root"
        )

    payload = canonical_manifest_payload(manifest)
    trusted_keys = root["keys"]
    verified_key_ids: set[str] = set()
    seen_signature_ids: set[str] = set()

    for entry in signatures:
        if not isinstance(entry, dict):
            raise PackSignatureError("signature entry must be an object")
        if entry.get("algorithm") != "ed25519":
            raise PackSignatureError("unsupported pack signature algorithm")
        key_id = entry.get("key_id")
        if not isinstance(key_id, str) or not key_id:
            raise PackSignatureError("signature entry missing key_id")
        if key_id in seen_signature_ids:
            raise PackSignatureError(f"duplicate signature key_id: {key_id}")
        seen_signature_ids.add(key_id)

        key = trusted_keys.get(key_id)
        if not isinstance(key, dict) or key.get("status") != "active":
            continue

        signature_bytes = _decode_hex(
            entry.get("value"), f"signature for {key_id}", 64
        )
        public_bytes = _decode_hex(
            key.get("keyval", {}).get("public"),
            f"public key for {key_id}",
            32,
        )
        try:
            Ed25519PublicKey.from_public_bytes(public_bytes).verify(
                signature_bytes, payload
            )
        except InvalidSignature:
            continue
        verified_key_ids.add(key_id)

    if len(verified_key_ids) < root["threshold"]:
        raise PackSignatureError(
            f"pack signature threshold not met: verified {len(verified_key_ids)}, "
            f"required {root['threshold']}"
        )
