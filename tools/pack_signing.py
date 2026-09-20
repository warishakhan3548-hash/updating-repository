#!/usr/bin/env python3
"""Trusted-key verification for immutable content-pack manifests.

Private release keys never belong in this repository. This module verifies
ECDSA P-256 / SHA-256 signatures against a project-controlled public-key policy.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec


ALGORITHM = "ecdsa-p256-sha256"
SIGNATURE_ENCODING = "base64-der"
PAYLOAD_FORMAT = "aaris-pack-json-v1"
DOMAIN_SEPARATOR = b"AARIS-CONTENT-PACK-SIGNATURE-V1\n"
MAX_SAFE_INTEGER = 9_007_199_254_740_991


class PackSignatureError(RuntimeError):
    pass


def _json_string(value: str) -> bytes:
    """Encode one JSON string with a small cross-language deterministic profile."""
    pieces = ['"']
    for ch in value:
        code = ord(ch)
        if 0xD800 <= code <= 0xDFFF:
            raise PackSignatureError("unpaired Unicode surrogate is forbidden")
        if ch == '"':
            pieces.append('\\"')
        elif ch == "\\":
            pieces.append("\\\\")
        elif code <= 0x1F:
            pieces.append(f"\\u{code:04x}")
        else:
            pieces.append(ch)
    pieces.append('"')
    return "".join(pieces).encode("utf-8")


def _canonical_json(value: Any) -> bytes:
    """Serialize the restricted manifest value set deterministically.

    Floats are rejected, integers are restricted to the JavaScript-safe range,
    object keys are sorted by Unicode scalar value, arrays preserve order, and
    strings use the project-owned escaping profile above. No Unicode
    normalization is performed: source strings are authenticated exactly as stored.
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

    The complete manifest except the top-level signature field is covered, so
    schema-v3 canonical bindings, provenance, toolchain metadata, hashes,
    review status and release_sequence are all authenticated together.
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


def public_key_id(public_key: ec.EllipticCurvePublicKey) -> str:
    if not isinstance(public_key.curve, ec.SECP256R1):
        raise PackSignatureError("trusted public key must use NIST P-256")
    der = public_key.public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    return "sha256:" + hashlib.sha256(der).hexdigest()


def _load_public_key(entry: dict[str, Any], key_id: str) -> ec.EllipticCurvePublicKey:
    raw = _strict_b64(
        entry.get("public_key_spki_base64"),
        f"{key_id}.public_key_spki_base64",
    )
    try:
        loaded = serialization.load_der_public_key(raw)
    except (ValueError, TypeError) as exc:
        raise PackSignatureError(
            f"{key_id}: invalid SubjectPublicKeyInfo public key"
        ) from exc
    if not isinstance(loaded, ec.EllipticCurvePublicKey):
        raise PackSignatureError(f"{key_id}: trusted public key must be elliptic-curve")
    if not isinstance(loaded.curve, ec.SECP256R1):
        raise PackSignatureError(f"{key_id}: trusted public key must use NIST P-256")
    if public_key_id(loaded) != key_id:
        raise PackSignatureError(
            f"{key_id}: public-key fingerprint does not match key_id"
        )
    return loaded


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
        if (
            not isinstance(key_id, str)
            or not key_id.startswith("sha256:")
            or len(key_id) != 71
            or any(ch not in "0123456789abcdef" for ch in key_id[7:])
            or key_id in keys
        ):
            raise PackSignatureError(
                f"invalid or duplicate trusted key_id: {key_id!r}"
            )
        if entry.get("algorithm") != ALGORITHM:
            raise PackSignatureError(
                f"{key_id}: unsupported trusted key algorithm"
            )
        status = entry.get("status")
        if status not in {"active", "retired", "revoked"}:
            raise PackSignatureError(f"{key_id}: invalid trusted key status")

        allowed = entry.get("allowed_pack_ids")
        if allowed is not None and (
            not isinstance(allowed, list)
            or not allowed
            or any(not isinstance(item, str) or not item for item in allowed)
            or len(set(allowed)) != len(allowed)
        ):
            raise PackSignatureError(f"{key_id}: invalid allowed_pack_ids")

        for field in ("min_release_sequence", "max_release_sequence"):
            bound = entry.get(field)
            if bound is not None and (
                isinstance(bound, bool) or not isinstance(bound, int) or bound < 1
            ):
                raise PackSignatureError(
                    f"{key_id}: {field} must be a positive integer"
                )
        minimum = entry.get("min_release_sequence")
        maximum = entry.get("max_release_sequence")
        if minimum is not None and maximum is not None and minimum > maximum:
            raise PackSignatureError(
                f"{key_id}: release-sequence window is inverted"
            )

        key = _load_public_key(entry, key_id)
        keys[key_id] = {**entry, "_public_key": key}

    return threshold, keys


def validate_trusted_key_policy(path: Path) -> None:
    """Validate key-policy syntax even before a production key is enrolled."""
    _load_policy(path)


def _key_authorized(
    entry: dict[str, Any],
    manifest: dict[str, Any],
    sequence: int,
) -> bool:
    if entry["status"] == "revoked":
        return False
    allowed = entry.get("allowed_pack_ids")
    if allowed is not None and manifest.get("pack_id") not in allowed:
        return False
    minimum = entry.get("min_release_sequence")
    maximum = entry.get("max_release_sequence")
    if minimum is not None and sequence < minimum:
        return False
    if maximum is not None and sequence > maximum:
        return False
    return True


def verify_manifest_signature(
    manifest: dict[str, Any],
    trusted_keys_path: Path,
) -> tuple[str, ...]:
    """Verify an approved manifest against trusted project release keys.

    Active and retired keys can validate releases inside their declared sequence
    window; revoked keys never count. Multiple signatures from one key count once.
    """
    if manifest.get("review_status") != "approved":
        raise PackSignatureError(
            "signature verification is only valid for approved packs"
        )

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
        raise PackSignatureError(
            "approved pack requires one or more signatures"
        )

    threshold, trusted = _load_policy(trusted_keys_path)
    payload = signature_payload(manifest)
    valid_key_ids: set[str] = set()

    for candidate in signatures:
        if not isinstance(candidate, dict):
            continue
        if candidate.get("algorithm") != ALGORITHM:
            continue
        if candidate.get("encoding") != SIGNATURE_ENCODING:
            continue
        key_id = candidate.get("key_id")
        if not isinstance(key_id, str) or key_id in valid_key_ids:
            continue
        entry = trusted.get(key_id)
        if entry is None or not _key_authorized(
            entry,
            manifest,
            release_sequence,
        ):
            continue
        try:
            signature = _strict_b64(
                candidate.get("value"),
                f"signature[{key_id}]",
            )
        except PackSignatureError:
            continue
        try:
            entry["_public_key"].verify(
                signature,
                payload,
                ec.ECDSA(hashes.SHA256()),
            )
        except (InvalidSignature, ValueError):
            continue
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
        print(
            f"Trusted pack key policy FAILED: {exc}",
            file=__import__("sys").stderr,
        )
        raise SystemExit(1)
    print("Trusted pack key policy OK")


if __name__ == "__main__":
    main()
