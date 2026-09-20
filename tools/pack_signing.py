#!/usr/bin/env python3
"""Trusted-key verification for immutable content-pack manifests.

Private release keys never belong in this repository. This module verifies
Ed25519 signatures against a project-controlled public-key policy.
"""
from __future__ import annotations

import base64
import binascii
import json
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


PAYLOAD_FORMAT = "aaris-pack-json-v1"
DOMAIN_SEPARATOR = b"AARIS-CONTENT-PACK-SIGNATURE-V1\n"
MAX_SAFE_INTEGER = 9_007_199_254_740_991


class PackSignatureError(RuntimeError):
    pass


def _json_string(value: str) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")


def _canonical_json(value: Any) -> bytes:
    """Serialize the restricted manifest value set deterministically.

    The signing format rejects floats so different runtimes never disagree
    about numeric rendering. Object keys are sorted by Unicode scalar value;
    manifest schema keys are ASCII. Strings are preserved as supplied.
    """
    if value is None:
        return b"null"
    if value is True:
        return b"true"
    if value is False:
        return b"false"
    if isinstance(value, int):
        if abs(value) > MAX_SAFE_INTEGER:
            raise PackSignatureError("integer is outside cross-runtime safe range")
        return str(value).encode("ascii")
    if isinstance(value, float):
        raise PackSignatureError("floats are forbidden in signed pack manifests")
    if isinstance(value, str):
        return _json_string(value)
    if isinstance(value, list):
        return b"[" + b",".join(_canonical_json(item) for item in value) + b"]"
    if isinstance(value, dict):
        if any(not isinstance(key, str) for key in value):
            raise PackSignatureError("signed manifest object keys must be strings")
        items = []
        for key in sorted(value):
            items.append(_json_string(key) + b":" + _canonical_json(value[key]))
        return b"{" + b",".join(items) + b"}"
    raise PackSignatureError(
        f"unsupported signed manifest value type: {type(value).__name__}"
    )


def signature_payload(manifest: dict[str, Any]) -> bytes:
    """Return exact bytes covered by release signatures.

    The whole manifest except the top-level signature field is authenticated.
    """
    if not isinstance(manifest, dict):
        raise PackSignatureError("manifest must be a JSON object")
    unsigned = {key: value for key, value in manifest.items() if key != "signature"}
    return DOMAIN_SEPARATOR + _canonical_json(unsigned)


def _strict_b64(value: object, field: str) -> bytes:
    if not isinstance(value, str) or not value:
        raise PackSignatureError(f"missing {field}")
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise PackSignatureError(f"invalid base64 in {field}") from exc


def verify_ed25519_signature(
    public_key: bytes,
    signature: bytes,
    payload: bytes,
) -> bool:
    if len(public_key) != 32:
        raise PackSignatureError("Ed25519 public key must be 32 bytes")
    if len(signature) != 64:
        return False
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, payload)
    except (InvalidSignature, ValueError):
        return False
    return True


def _load_policy(path: Path) -> tuple[int, dict[str, dict[str, Any]]]:
    try:
        policy = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PackSignatureError(f"cannot load trusted pack keys: {path}") from exc

    if policy.get("schema_version") != 1:
        raise PackSignatureError("unsupported trusted pack key schema_version")
    threshold = policy.get("signature_threshold")
    if isinstance(threshold, bool) or not isinstance(threshold, int) or threshold < 1:
        raise PackSignatureError("signature_threshold must be a positive integer")

    raw_keys = policy.get("keys")
    if not isinstance(raw_keys, list):
        raise PackSignatureError("trusted pack keys must be a list")

    keys: dict[str, dict[str, Any]] = {}
    for entry in raw_keys:
        if not isinstance(entry, dict):
            raise PackSignatureError("trusted pack key entry must be an object")
        key_id = entry.get("key_id")
        if not isinstance(key_id, str) or not key_id or key_id in keys:
            raise PackSignatureError(f"invalid or duplicate trusted key_id: {key_id!r}")
        if entry.get("algorithm") != "ed25519":
            raise PackSignatureError(f"{key_id}: unsupported trusted key algorithm")
        status = entry.get("status")
        if status not in {"active", "retired", "revoked"}:
            raise PackSignatureError(f"{key_id}: invalid trusted key status")
        public_key = _strict_b64(entry.get("public_key_base64"), f"{key_id}.public_key")
        if len(public_key) != 32:
            raise PackSignatureError(f"{key_id}: Ed25519 public key must be 32 bytes")
        keys[key_id] = {**entry, "_public_key": public_key}

    return threshold, keys


def validate_trusted_key_policy(path: Path) -> None:
    """Validate key-policy syntax even before any release key is enrolled."""
    _load_policy(path)


def verify_manifest_signature(
    manifest: dict[str, Any],
    trusted_keys_path: Path,
) -> tuple[str, ...]:
    """Verify an approved manifest against trusted project release keys.

    Active and retired keys may verify historical packs. Revoked keys never
    count. Multiple signatures from one key count once. The threshold allows
    rotation or later multi-key hardening without changing the payload format.
    """
    release_sequence = manifest.get("release_sequence")
    if (
        isinstance(release_sequence, bool)
        or not isinstance(release_sequence, int)
        or release_sequence < 1
    ):
        raise PackSignatureError(
            "approved pack requires positive integer release_sequence"
        )

    signature_block = manifest.get("signature")
    if not isinstance(signature_block, dict):
        raise PackSignatureError("approved pack requires signature object")
    if signature_block.get("status") != "signed":
        raise PackSignatureError("approved pack signature status must be signed")
    if signature_block.get("payload_format") != PAYLOAD_FORMAT:
        raise PackSignatureError(
            f"approved pack requires payload_format {PAYLOAD_FORMAT}"
        )

    signatures = signature_block.get("signatures")
    if not isinstance(signatures, list) or not signatures:
        raise PackSignatureError("approved pack requires one or more signatures")

    threshold, trusted = _load_policy(trusted_keys_path)
    payload = signature_payload(manifest)
    valid_key_ids: set[str] = set()

    for candidate in signatures:
        if not isinstance(candidate, dict):
            continue
        if candidate.get("algorithm") != "ed25519":
            continue
        key_id = candidate.get("key_id")
        if not isinstance(key_id, str) or key_id in valid_key_ids:
            continue
        key = trusted.get(key_id)
        if key is None or key["status"] == "revoked":
            continue
        try:
            signature = _strict_b64(
                candidate.get("value"),
                f"signature[{key_id}]",
            )
        except PackSignatureError:
            continue
        if verify_ed25519_signature(key["_public_key"], signature, payload):
            valid_key_ids.add(key_id)

    if len(valid_key_ids) < threshold:
        raise PackSignatureError(
            f"trusted signature threshold not met: "
            f"{len(valid_key_ids)}/{threshold}"
        )
    return tuple(sorted(valid_key_ids))


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(
        description="Validate the project trusted content-pack public-key policy."
    )
    parser.add_argument(
        "policy",
        nargs="?",
        type=Path,
        default=Path("policy/trusted_pack_keys.json"),
    )
    args = parser.parse_args()
    try:
        validate_trusted_key_policy(args.policy)
    except PackSignatureError as exc:
        print(f"Trusted pack key policy FAILED: {exc}", file=__import__("sys").stderr)
        raise SystemExit(1)
    print("Trusted pack key policy OK")


if __name__ == "__main__":
    main()
