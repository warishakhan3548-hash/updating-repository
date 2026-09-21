#!/usr/bin/env python3
"""Offline-only helper for inspecting and signing content-pack release manifests.

This tool never generates or stores release private keys. It accepts only an
encrypted PKCS#8 PEM located outside the repository, prompts for its password,
derives the project key ID, and can append one Ed25519 signature to an already
approved manifest using the project-owned canonical signing contract.
"""
from __future__ import annotations

import argparse
import getpass
import json
from pathlib import Path
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.pack_signatures import (
    MAX_SAFE_INTEGER,
    RELEASE_ROLE,
    SIGNATURE_FORMAT,
    PackSignatureError,
    canonical_manifest_payload,
    key_id_for_ed25519_public_key,
    load_strict_json_file,
    validate_trusted_key_policy,
)
from tools.release_freshness import (
    ReleaseFreshnessError,
    validate_release_window,
)


class ReleaseSigningError(RuntimeError):
    pass


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def require_private_key_outside_repo(path: Path, repo_root: Path | None = None) -> Path:
    resolved = path.expanduser().resolve()
    root = (repo_root or _repo_root()).resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        return resolved
    raise ReleaseSigningError(
        "release private key must be stored outside the repository"
    )


def load_encrypted_ed25519_private_key(
    path: Path,
    password: bytes,
    *,
    repo_root: Path | None = None,
):
    key_path = require_private_key_outside_repo(path, repo_root)
    try:
        pem = key_path.read_bytes()
    except OSError as exc:
        raise ReleaseSigningError(f"cannot read private key: {key_path}") from exc

    if b"-----BEGIN ENCRYPTED PRIVATE KEY-----" not in pem:
        raise ReleaseSigningError(
            "release private key must be encrypted PKCS#8 PEM"
        )
    if not password:
        raise ReleaseSigningError("private-key password must not be empty")

    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import (
            Ed25519PrivateKey,
        )

        key = serialization.load_pem_private_key(pem, password=password)
    except ImportError as exc:
        raise ReleaseSigningError(
            "release signer requires the pinned cryptography dependency"
        ) from exc
    except (TypeError, ValueError) as exc:
        raise ReleaseSigningError(
            "cannot decrypt or parse release private key"
        ) from exc

    if not isinstance(key, Ed25519PrivateKey):
        raise ReleaseSigningError("release private key is not Ed25519")
    return key


def public_key_record(private_key) -> dict[str, str]:
    try:
        from cryptography.hazmat.primitives import serialization
    except ImportError as exc:
        raise ReleaseSigningError(
            "release signer requires the pinned cryptography dependency"
        ) from exc

    public_hex = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    ).hex()
    return {
        "algorithm": "ed25519",
        "public_key": public_hex,
        "key_id": key_id_for_ed25519_public_key(public_hex),
    }


def _release_sequence(manifest: dict[str, Any]) -> int:
    value = manifest.get("release_sequence")
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value < 1
        or value > MAX_SAFE_INTEGER
    ):
        raise ReleaseSigningError(
            "approved manifest needs a positive cross-runtime-safe release_sequence"
        )
    return value


def _existing_signatures(manifest: dict[str, Any]) -> list[dict[str, str]]:
    block = manifest.get("signature")
    if block == {"status": "unsigned"}:
        return []
    if not isinstance(block, dict):
        raise ReleaseSigningError("manifest signature block must be an object")
    if block.get("format") != SIGNATURE_FORMAT or block.get("role") != RELEASE_ROLE:
        raise ReleaseSigningError("manifest uses an incompatible signature block")
    entries = block.get("signatures")
    if not isinstance(entries, list):
        raise ReleaseSigningError("manifest signature entries must be a list")

    seen: set[str] = set()
    normalized: list[dict[str, str]] = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {
            "algorithm",
            "key_id",
            "value",
        }:
            raise ReleaseSigningError("manifest contains malformed signature entry")
        if entry.get("algorithm") != "ed25519":
            raise ReleaseSigningError("manifest contains unsupported signature algorithm")
        key_id = entry.get("key_id")
        value = entry.get("value")
        if (
            not isinstance(key_id, str)
            or len(key_id) != 64
            or any(ch not in "0123456789abcdef" for ch in key_id)
            or key_id in seen
        ):
            raise ReleaseSigningError("manifest contains invalid/duplicate signature key")
        if (
            not isinstance(value, str)
            or len(value) != 128
            or any(ch not in "0123456789abcdef" for ch in value)
        ):
            raise ReleaseSigningError("manifest contains invalid signature bytes")
        seen.add(key_id)
        normalized.append(dict(entry))
    return normalized


def sign_manifest(
    manifest: dict[str, Any],
    private_key,
    trusted_key_policy: Path,
) -> dict[str, Any]:
    if manifest.get("review_status") != "approved":
        raise ReleaseSigningError(
            "refusing to sign: manifest review_status must already be approved"
        )
    sequence = _release_sequence(manifest)
    try:
        validate_release_window(manifest)
    except ReleaseFreshnessError as exc:
        raise ReleaseSigningError(
            f"approved manifest has invalid release freshness: {exc}"
        ) from exc
    record = public_key_record(private_key)
    key_id = record["key_id"]

    try:
        keys, authorized, _ = validate_trusted_key_policy(
            trusted_key_policy,
            require_active=True,
        )
    except PackSignatureError as exc:
        raise ReleaseSigningError(f"invalid active trust policy: {exc}") from exc

    if key_id not in authorized or key_id not in keys:
        raise ReleaseSigningError("private key is not authorized for release role")
    key = keys[key_id]
    if key.get("status") != "active":
        raise ReleaseSigningError("offline signer only permits active release keys")
    if sequence < key["min_release_sequence"]:
        raise ReleaseSigningError("release sequence is below this key's validity window")
    maximum = key["max_release_sequence"]
    if maximum is not None and sequence > maximum:
        raise ReleaseSigningError("release sequence is above this key's validity window")

    existing = _existing_signatures(manifest)
    if any(entry["key_id"] == key_id for entry in existing):
        raise ReleaseSigningError("manifest is already signed by this release key")

    try:
        payload = canonical_manifest_payload(manifest)
    except PackSignatureError as exc:
        raise ReleaseSigningError(f"manifest is not signable: {exc}") from exc

    signature = private_key.sign(payload)
    try:
        private_key.public_key().verify(signature, payload)
    except Exception as exc:  # pragma: no cover - defensive cryptographic self-check
        raise ReleaseSigningError("generated signature failed self-verification") from exc

    signed = dict(manifest)
    signed["signature"] = {
        "format": SIGNATURE_FORMAT,
        "role": RELEASE_ROLE,
        "signatures": [
            *existing,
            {
                "algorithm": "ed25519",
                "key_id": key_id,
                "value": signature.hex(),
            },
        ],
    }
    return signed


def write_new_manifest(path: Path, manifest: dict[str, Any]) -> None:
    output = path.expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(
        manifest,
        ensure_ascii=False,
        sort_keys=True,
        indent=2,
        allow_nan=False,
    ) + "\n"
    try:
        with output.open("x", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
    except FileExistsError as exc:
        raise ReleaseSigningError(
            f"refusing to overwrite existing output: {output}"
        ) from exc


def _password_prompt() -> bytes:
    password = getpass.getpass("Encrypted release-key password: ")
    if not password:
        raise ReleaseSigningError("private-key password must not be empty")
    return password.encode("utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Inspect or sign with an offline encrypted Ed25519 release key."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    inspect_parser = sub.add_parser(
        "inspect-key",
        help="Print public key and project key ID; never prints private material.",
    )
    inspect_parser.add_argument("private_key", type=Path)

    sign_parser = sub.add_parser(
        "sign",
        help="Append one authorized Ed25519 signature to an approved manifest.",
    )
    sign_parser.add_argument("manifest", type=Path)
    sign_parser.add_argument("private_key", type=Path)
    sign_parser.add_argument("trusted_key_policy", type=Path)
    sign_parser.add_argument("output", type=Path)

    args = parser.parse_args(argv)
    try:
        private_key = load_encrypted_ed25519_private_key(
            args.private_key,
            _password_prompt(),
        )
        if args.command == "inspect-key":
            print(
                json.dumps(
                    public_key_record(private_key),
                    sort_keys=True,
                    indent=2,
                )
            )
            return 0

        manifest = load_strict_json_file(args.manifest, label="pack manifest")
        if not isinstance(manifest, dict):
            raise ReleaseSigningError("pack manifest must be a JSON object")
        if args.output.expanduser().resolve() == args.manifest.expanduser().resolve():
            raise ReleaseSigningError(
                "refusing to overwrite the input manifest; sign into a new file"
            )
        signed = sign_manifest(
            manifest,
            private_key,
            args.trusted_key_policy,
        )
        write_new_manifest(args.output, signed)
        print(
            json.dumps(
                {
                    "output": str(args.output),
                    "key_id": public_key_record(private_key)["key_id"],
                    "release_sequence": signed["release_sequence"],
                    "signature_count": len(signed["signature"]["signatures"]),
                },
                sort_keys=True,
            )
        )
        return 0
    except (OSError, PackSignatureError, ReleaseSigningError) as exc:
        print(f"Release signing FAILED: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
