#!/usr/bin/env python3
"""Cryptographic verification for approved content-pack manifests.

The signed payload is the complete manifest with the top-level signature field
removed, serialized as deterministic UTF-8 JSON. Private keys never belong in the
repository; this module only handles public-key trust and verification.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


SIGNATURE_FORMAT = "aaris-pack-signature-v1"
RELEASE_ROLE = "content-pack-release"
KEYRING_SCHEMA_VERSION = 1


class PackSignatureError(RuntimeError):
    pass


def _reject_float(value: Any, path: str = "$") -> None:
    if isinstance(value, float):
        raise PackSignatureError(
            f"floating-point value is not allowed in signed metadata at {path}"
        )
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str):
                raise PackSignatureError(f"non-string JSON object key at {path}")
            _reject_float(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _reject_float(child, f"{path}[{index}]")


def canonical_json_bytes(value: Any) -> bytes:
    """Serialize a restricted JSON value deterministically for signatures."""
    _reject_float(value)
    try:
        text = json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
    except (TypeError, ValueError) as exc:
        raise PackSignatureError(
            "signed metadata is not canonicalizable JSON"
        ) from exc
    return text.encode("utf-8")


def canonical_manifest_payload(manifest: dict[str, Any]) -> bytes:
    if not isinstance(manifest, dict):
        raise PackSignatureError("manifest must be a JSON object")
    payload = dict(manifest)
    if "signature" not in payload:
        raise PackSignatureError("manifest is missing signature field")
    payload.pop("signature")
    return canonical_json_bytes(payload)


def key_id_for_ed25519_public_key(public_key_hex: str) -> str:
    raw = _decode_hex(public_key_hex, expected_bytes=32, field="public_key")
    key_object = {
        "algorithm": "ed25519",
        "public_key": raw.hex(),
    }
    return hashlib.sha256(canonical_json_bytes(key_object)).hexdigest()


def _decode_hex(value: object, *, expected_bytes: int, field: str) -> bytes:
    if not isinstance(value, str) or len(value) != expected_bytes * 2:
        raise PackSignatureError(f"invalid {field}")
    if any(ch not in "0123456789abcdef" for ch in value):
        raise PackSignatureError(f"invalid {field}")
    try:
        return bytes.fromhex(value)
    except ValueError as exc:
        raise PackSignatureError(f"invalid {field}") from exc


def _load_keyring(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise PackSignatureError(f"missing trusted pack key policy: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PackSignatureError("invalid trusted pack key policy JSON") from exc
    if (
        not isinstance(data, dict)
        or data.get("schema_version") != KEYRING_SCHEMA_VERSION
    ):
        raise PackSignatureError("unsupported trusted pack key policy schema")
    state = data.get("state")
    if state not in {"bootstrap-required", "active"}:
        raise PackSignatureError("invalid trusted pack key policy state")
    return data


def validate_trusted_key_policy(
    path: Path,
    *,
    require_active: bool = False,
) -> tuple[dict[str, Any], set[str], int]:
    """Validate the project trust root even while it is still bootstrapping."""
    keyring = _load_keyring(path)
    state = keyring.get("state")
    if require_active and state != "active":
        raise PackSignatureError("trusted pack key policy is not active")

    keys = keyring.get("keys")
    roles = keyring.get("roles")
    if not isinstance(keys, dict) or not isinstance(roles, dict):
        raise PackSignatureError(
            "trusted pack key policy must define keys and roles"
        )

    release = roles.get(RELEASE_ROLE)
    if not isinstance(release, dict):
        raise PackSignatureError(
            f"trusted pack key policy lacks {RELEASE_ROLE} role"
        )
    threshold = release.get("threshold")
    key_ids = release.get("key_ids")
    if (
        not isinstance(threshold, int)
        or isinstance(threshold, bool)
        or threshold < 1
    ):
        raise PackSignatureError("invalid release signature threshold")
    if (
        not isinstance(key_ids, list)
        or any(
            not isinstance(key_id, str) or not key_id for key_id in key_ids
        )
        or len(set(key_ids)) != len(key_ids)
    ):
        raise PackSignatureError("invalid release role key_ids")

    for key_id, key in keys.items():
        if not isinstance(key_id, str) or not key_id:
            raise PackSignatureError("invalid trusted key id")
        if not isinstance(key, dict):
            raise PackSignatureError(f"invalid trusted key {key_id}")
        if key.get("algorithm") != "ed25519":
            raise PackSignatureError(
                f"unsupported trusted-key algorithm for {key_id}"
            )
        computed_id = key_id_for_ed25519_public_key(
            key.get("public_key")
        )
        if key_id != computed_id:
            raise PackSignatureError(
                f"trusted key id mismatch for {key_id}"
            )

    authorized = set(key_ids)
    missing = [key_id for key_id in key_ids if key_id not in keys]
    if missing:
        raise PackSignatureError(
            f"release role references missing trusted key {missing[0]}"
        )
    if state == "active" and threshold > len(key_ids):
        raise PackSignatureError(
            "release signature threshold exceeds authorized key count"
        )
    return keys, authorized, threshold


def _verify_ed25519(
    public_key: bytes,
    signature: bytes,
    payload: bytes,
) -> None:
    try:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives.asymmetric.ed25519 import (
            Ed25519PublicKey,
        )
    except ImportError as exc:
        raise PackSignatureError(
            "Ed25519 verifier unavailable; install the pinned CI/release "
            "cryptography dependency"
        ) from exc

    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(
            signature, payload
        )
    except InvalidSignature as exc:
        raise PackSignatureError(
            "invalid Ed25519 manifest signature"
        ) from exc
    except ValueError as exc:
        raise PackSignatureError("invalid Ed25519 public key") from exc


def verify_approved_manifest(
    manifest: dict[str, Any],
    keyring_path: Path,
) -> int:
    """Verify an approved manifest against project-controlled trusted keys."""
    if manifest.get("review_status") != "approved":
        raise PackSignatureError(
            "signature verification is only defined for approved packs"
        )

    signature_block = manifest.get("signature")
    if not isinstance(signature_block, dict):
        raise PackSignatureError(
            "approved pack signature must be an object"
        )
    if signature_block.get("format") != SIGNATURE_FORMAT:
        raise PackSignatureError(
            f"approved pack requires signature format {SIGNATURE_FORMAT}"
        )
    if signature_block.get("role") != RELEASE_ROLE:
        raise PackSignatureError(
            f"approved pack signature role must be {RELEASE_ROLE}"
        )
    signatures = signature_block.get("signatures")
    if not isinstance(signatures, list) or not signatures:
        raise PackSignatureError(
            "approved pack requires at least one signature"
        )

    keys, authorized, threshold = validate_trusted_key_policy(
        keyring_path,
        require_active=True,
    )
    payload = canonical_manifest_payload(manifest)

    seen: set[str] = set()
    verified = 0
    for entry in signatures:
        if not isinstance(entry, dict):
            raise PackSignatureError(
                "signature entry must be an object"
            )
        if set(entry) != {"algorithm", "key_id", "value"}:
            raise PackSignatureError(
                "signature entry has unexpected or missing fields"
            )
        algorithm = entry.get("algorithm")
        key_id = entry.get("key_id")
        value = entry.get("value")
        if algorithm != "ed25519":
            raise PackSignatureError(
                "unsupported pack signature algorithm"
            )
        if (
            not isinstance(key_id, str)
            or key_id not in authorized
        ):
            raise PackSignatureError(
                "pack signature key is not authorized for release"
            )
        if key_id in seen:
            raise PackSignatureError(
                "duplicate pack signature key_id"
            )
        seen.add(key_id)

        signature = _decode_hex(
            value,
            expected_bytes=64,
            field="signature value",
        )
        key = keys[key_id]
        public_key = _decode_hex(
            key.get("public_key"),
            expected_bytes=32,
            field="trusted public_key",
        )
        _verify_ed25519(public_key, signature, payload)
        verified += 1

    if verified < threshold:
        raise PackSignatureError(
            f"release signature threshold not met: "
            f"{verified}/{threshold}"
        )
    return verified
