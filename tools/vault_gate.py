#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

ALLOWED_STATUSES = {
    "research-candidate",
    "awaiting-artifact",
    "awaiting-licence",
    "production-approved",
    "rejected",
}


class VaultGateError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_vault_file(root: Path, raw: object, source_id: str, field: str) -> Path:
    if not isinstance(raw, str) or not raw:
        raise VaultGateError(f"{source_id}: missing {field}")
    rel = Path(raw)
    if rel.is_absolute() or ".." in rel.parts or not rel.parts or rel.parts[0] != "source-vault":
        raise VaultGateError(f"{source_id}: {field} must be under source-vault/")
    path = root / rel
    if not path.is_file():
        raise VaultGateError(f"{source_id}: missing file {rel}")
    vault_root = (root / "source-vault").resolve()
    try:
        path.resolve().relative_to(vault_root)
    except ValueError as exc:
        raise VaultGateError(
            f"{source_id}: {field} resolves outside source-vault/"
        ) from exc
    return path


def validate_registry(registry_path: Path) -> None:
    registry_path = registry_path.resolve()
    root = registry_path.parents[1]
    data = json.loads(registry_path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        raise VaultGateError("Unsupported source-vault registry schema_version")

    sources = data.get("sources")
    if not isinstance(sources, list):
        raise VaultGateError("Registry sources must be a list")

    seen: set[str] = set()
    for source in sources:
        if not isinstance(source, dict):
            raise VaultGateError("Each source registry entry must be an object")
        source_id = source.get("source_id")
        if not isinstance(source_id, str) or not source_id or source_id in seen:
            raise VaultGateError(f"Missing or duplicate source_id: {source_id!r}")
        seen.add(source_id)

        status = source.get("status")
        if status not in ALLOWED_STATUSES:
            raise VaultGateError(f"{source_id}: invalid status {status!r}")

        if status != "production-approved":
            continue

        original_url = source.get("original_url")
        parsed_url = urlparse(original_url) if isinstance(original_url, str) else None
        if (
            parsed_url is None
            or parsed_url.scheme != "https"
            or not parsed_url.netloc
        ):
            raise VaultGateError(
                f"{source_id}: production original_url must be an absolute https URL"
            )

        if source.get("redistribution_allowed") is not True:
            raise VaultGateError(
                f"{source_id}: production source lacks verified redistribution permission"
            )

        artifact = _safe_vault_file(
            root, source.get("vault_artifact"), source_id, "vault_artifact"
        )
        licence = _safe_vault_file(
            root, source.get("licence_snapshot"), source_id, "licence_snapshot"
        )
        provenance_path = _safe_vault_file(
            root, source.get("provenance"), source_id, "provenance"
        )
        if len({artifact.resolve(), licence.resolve(), provenance_path.resolve()}) != 3:
            raise VaultGateError(
                f"{source_id}: artifact/licence/provenance must be distinct files"
            )
        if licence.stat().st_size == 0:
            raise VaultGateError(f"{source_id}: licence snapshot is empty")

        expected_size = source.get("byte_size")
        expected_hash = source.get("sha256")
        if not isinstance(expected_size, int) or expected_size < 1:
            raise VaultGateError(f"{source_id}: invalid byte_size")
        if (
            not isinstance(expected_hash, str)
            or len(expected_hash) != 64
            or any(ch not in "0123456789abcdef" for ch in expected_hash)
        ):
            raise VaultGateError(f"{source_id}: invalid lowercase sha256")

        actual_size = artifact.stat().st_size
        actual_hash = sha256_file(artifact)
        if actual_size != expected_size:
            raise VaultGateError(f"{source_id}: artifact byte_size mismatch")
        if actual_hash != expected_hash:
            raise VaultGateError(f"{source_id}: artifact SHA-256 mismatch")

        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        required = [
            "source_id",
            "source_name",
            "original_url",
            "version",
            "retrieved_at",
            "sha256",
            "byte_size",
            "licence_id",
            "redistribution_allowed",
            "project_mirror",
        ]
        missing = [key for key in required if provenance.get(key) in (None, "")]
        if missing:
            raise VaultGateError(f"{source_id}: provenance missing {missing}")
        if provenance["source_id"] != source_id:
            raise VaultGateError(f"{source_id}: provenance source_id mismatch")
        for key in ("source_name", "original_url", "version", "licence_id"):
            if provenance[key] != source.get(key):
                raise VaultGateError(f"{source_id}: provenance {key} mismatch")
        if provenance["redistribution_allowed"] is not True:
            raise VaultGateError(
                f"{source_id}: provenance does not confirm redistribution permission"
            )
        if (
            provenance["sha256"] != expected_hash
            or provenance["byte_size"] != expected_size
        ):
            raise VaultGateError(f"{source_id}: provenance integrity mismatch")

        mirror = provenance["project_mirror"]
        if mirror != source.get("vault_artifact"):
            raise VaultGateError(
                f"{source_id}: project_mirror must identify the pinned vault artifact"
            )


if __name__ == "__main__":
    try:
        path = Path(
            sys.argv[1] if len(sys.argv) > 1 else "source-vault/registry.json"
        )
        validate_registry(path)
    except (OSError, ValueError, json.JSONDecodeError, VaultGateError) as exc:
        print(f"Source Vault gate FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
    print("Source Vault gate OK")
