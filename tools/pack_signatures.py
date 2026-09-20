#!/usr/bin/env python3
"""Cryptographic verification for approved content-pack manifests.

The signed payload is the complete manifest with the top-level signature field
removed, domain-separated, and serialized as restricted deterministic UTF-8 JSON.
Private keys never belong in the repository; this module only handles public-key
trust and verification.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


SIGNATURE_FORMAT = "aaris-pack-signature-v1"
RELEASE_ROLE = "content-pack-release"
KEYRING_SCHEMA_VERSION = 1
SIGNATURE_PAYLOAD_DOMAIN = b"AARIS-CONTENT-PACK-SIGNATURE-V1\n"
MAX_SAFE_INTEGER = 9_007_199_254_740_991


class PackSignatureError(RuntimeError):
    pass


def _reject_duplicate_json_keys(pairs: list[tuple[str, object]]) -> dict:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise PackSignatureError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def _validate_canonical_value(value: Any, path: str = "$") -> None:
    if isinstance(value, float):
        raise PackSignatureError(
            f"floating-point value is not allowed in signed metadata at {path}"
        )
    if isinstance(value, int) and not isinstance(value, bool):
        if abs(value) > MAX_SAFE_INTEGER:
            raise PackSignatureError(
                f"integer is outside cross-runtime safe range at {path}"
            )
        return
    if isinstance(value, str):
        try:
            value.encode("utf-8")
        except UnicodeEncodeError as exc:
            raise PackSignatureError(
                f"invalid Unicode scalar value in signed metadata at {path}"
            ) from exc
        return
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str):
                raise PackSignatureError(f"non-string JSON object key at {path}")
            try:
                key.encode("utf-8")
            except UnicodeEncodeError as exc:
                raise PackSignatureError(
                    f"invalid Unicode scalar value in signed metadata key at {path}"
                ) from exc
            _validate_canonical_value(child, f"{path}.{key}")
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            _validate_canonical_value(child, f"{path}[{index}]")
        return
    if value is None or isinstance(value, bool):
        return
    raise PackSignatureError(
        f"unsupported signed metadata value at {path}: {type(value).__name__}"
    )


def canonical_json_bytes(value: Any) -> bytes:
    """Serialize the restricted signed-JSON value set deterministically."""
    _validate_canonical_value(value)
    try:
        text = json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        return text.encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as exc:
        raise PackSignatureError(
            "signed metadata is not canonicalizable JSON"
        ) from exc


def canonical_manifest_payload(manifest: dict[str, Any]) -> bytes:
    """Return domain-separated bytes authenticated by content-pack signatures."""
    if not isinstance(manifest, dict):
        raise PackSignatureError("manifest must be a JSON object")
    payload = dict(manifest)
    if "signature" not in payload:
        raise PackSignatureError("manifest is missing signature field")
    payload.pop("signature")
    return SIGNATURE_PAYLOAD_DOMAIN + canonical_json_bytes(payload)


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
        data = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_json_keys,
        )
    except PackSignatureError:
        raise
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


def _positive_sequence(value: object, field: str) -> int:
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value < 1
        or value > MAX_SAFE_INTEGER
    ):
        raise PackSignatureError(
            f"{field} must be a positive cross-runtime-safe integer"
        )
    return value


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
        if set(key) != {
            "algorithm",
            "public_key",
            "status",
            "min_release_sequence",
            "max_release_sequence",
        }:
            raise PackSignatureError(
                f"trusted key {key_id} has unexpected or missing fields"
            )
        if key.get("algorithm") != "ed25519":
            raise PackSignatureError(
                f"unsupported trusted-key algorithm for {key_id}"
            )
        computed_id = key_id_for_ed25519_public_key(key.get("public_key"))
        if key_id != computed_id:
            raise PackSignatureError(
                f"trusted key id mismatch for {key_id}"
            )

        status = key.get("status")
        if status not in {"active", "retired", "revoked"}:
            raise PackSignatureError(f"invalid trusted key status for {key_id}")
        minimum = _positive_sequence(
            key.get("min_release_sequence"),
            f"{key_id}.min_release_sequence",
        )
        maximum = key.get("max_release_sequence")
        if maximum is not None:
            maximum = _positive_sequence(
                maximum,
                f"{key_id}.max_release_sequence",
            )
            if maximum < minimum:
                raise PackSignatureError(
                    f"{key_id}.max_release_sequence is below minimum"
                )
        if status == "active" and maximum is not None:
            raise PackSignatureError(
                f"active trusted key {key_id} must not have max_release_sequence"
            )
        if status == "retired" and maximum is None:
            raise PackSignatureError(
                f"retired trusted key {key_id} requires max_release_sequence"
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

    release_sequence = _positive_sequence(
        manifest.get("release_sequence"),
        "release_sequence",
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
        if not isinstance(key_id, str) or key_id not in authorized:
            raise PackSignatureError(
                "pack signature key is not authorized for release"
            )
        if key_id in seen:
            raise PackSignatureError(
                "duplicate pack signature key_id"
            )
        seen.add(key_id)

        key = keys[key_id]
        if key["status"] == "revoked":
            raise PackSignatureError(
                "pack signature key is revoked"
            )
        minimum = key["min_release_sequence"]
        maximum = key["max_release_sequence"]
        if release_sequence < minimum or (
            maximum is not None and release_sequence > maximum
        ):
            raise PackSignatureError(
                "pack signature key is outside its trusted release-sequence window"
            )

        signature = _decode_hex(
            value,
            expected_bytes=64,
            field="signature value",
        )
        public_key = _decode_hex(
            key.get("public_key"),
            expected_bytes=32,
            field="trusted public_key",
        )
        _verify_ed25519(public_key, signature, payload)
        verified += 1

    if verified < threshold:
        raise PackSignatureError(
            f"release signature threshold not met: {verified}/{threshold}"
        )
    return verified
