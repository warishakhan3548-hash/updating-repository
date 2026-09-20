#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import re
import sys
from datetime import datetime
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse

ALLOWED_STATUSES = {
    "research-candidate",
    "awaiting-artifact",
    "awaiting-licence",
    "production-approved",
    "rejected",
}

ALLOWED_ARTIFACT_KINDS = {"file", "sha256-set"}
CHECKSUM_LINE_RE = re.compile(r"^([0-9a-f]{64})  ([^\r\n]+)$")

REQUIRED_RELEASE_RULES = {
    "require_production_approved",
    "require_redistribution_allowed",
    "require_commercial_use_allowed",
    "require_historical_snapshot_retention_allowed",
    "require_exact_sha256",
    "require_licence_snapshot",
    "require_project_controlled_artifact",
    "forbid_runtime_upstream_download",
    "forbid_unknown_licence_in_release",
}

PRESERVED_SNAPSHOT_FIELDS = (
    "vault_artifact",
    "licence_snapshot",
    "provenance",
    "sha256",
    "licence_sha256",
    "provenance_sha256",
    "byte_size",
)


class VaultGateError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _lower_sha256(value: object, source_id: str, field: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(ch not in "0123456789abcdef" for ch in value)
    ):
        raise VaultGateError(f"{source_id}: invalid lowercase {field}")
    return value


def _load_policy(root: Path) -> None:
    policy_path = root / "policy" / "license_policy.json"
    try:
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise VaultGateError("Missing policy/license_policy.json") from exc

    if policy.get("schema_version") != 1:
        raise VaultGateError("Unsupported licence policy schema_version")
    rules = policy.get("release_rules")
    if not isinstance(rules, dict):
        raise VaultGateError("Licence policy release_rules must be an object")

    weakened = sorted(
        rule for rule in REQUIRED_RELEASE_RULES if rules.get(rule) is not True
    )
    if weakened:
        raise VaultGateError(
            "Licence policy weakens mandatory release rules: " + ", ".join(weakened)
        )


def _parse_retrieved_at(value: object, source_id: str) -> None:
    if not isinstance(value, str) or not value:
        raise VaultGateError(f"{source_id}: provenance retrieved_at missing")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise VaultGateError(
            f"{source_id}: provenance retrieved_at is not ISO-8601"
        ) from exc
    if parsed.tzinfo is None:
        raise VaultGateError(
            f"{source_id}: provenance retrieved_at must include a timezone"
        )


def _validate_release_requirements(source: dict, source_id: str) -> dict | None:
    requirements = source.get("release_requirements")
    if requirements is None:
        return None
    expected_fields = {
        "latest_upstream_version_required",
        "version_check_url",
        "historical_snapshot_retention_status",
    }
    if not isinstance(requirements, dict) or set(requirements) != expected_fields:
        raise VaultGateError(
            f"{source_id}: release_requirements must contain exactly "
            f"{sorted(expected_fields)}"
        )
    if not isinstance(requirements.get("latest_upstream_version_required"), bool):
        raise VaultGateError(
            f"{source_id}: latest_upstream_version_required must be boolean"
        )
    retention_status = requirements.get("historical_snapshot_retention_status")
    if retention_status not in {
        "unresolved",
        "verified-allowed",
        "verified-not-allowed",
    }:
        raise VaultGateError(
            f"{source_id}: invalid historical_snapshot_retention_status"
        )
    raw_url = requirements.get("version_check_url")
    parsed = urlparse(raw_url) if isinstance(raw_url, str) else None
    if parsed is None or parsed.scheme != "https" or not parsed.netloc:
        raise VaultGateError(
            f"{source_id}: release version_check_url must be an absolute https URL"
        )
    return requirements


def _safe_vault_file(root: Path, raw: object, source_id: str, field: str) -> Path:
    if not isinstance(raw, str) or not raw:
        raise VaultGateError(f"{source_id}: missing {field}")
    rel = Path(raw)
    if (
        rel.is_absolute()
        or ".." in rel.parts
        or not rel.parts
        or rel.parts[0] != "source-vault"
    ):
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


def _validate_checksum_set(artifact: Path, source_id: str) -> int:
    if artifact.is_symlink():
        raise VaultGateError(
            f"{source_id}: checksum-set artifact must not be a symlink"
        )
    try:
        text = artifact.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise VaultGateError(
            f"{source_id}: checksum-set artifact must be UTF-8"
        ) from exc

    lines = text.splitlines()
    if not lines:
        raise VaultGateError(f"{source_id}: checksum-set artifact is empty")

    snapshot_root = artifact.parent.resolve()
    seen_paths: set[str] = set()
    seen_targets: set[Path] = set()

    for line_number, line in enumerate(lines, start=1):
        match = CHECKSUM_LINE_RE.fullmatch(line)
        if match is None:
            raise VaultGateError(
                f"{source_id}: invalid checksum-set line {line_number}"
            )
        expected_hash, raw_path = match.groups()
        if "\\" in raw_path:
            raise VaultGateError(
                f"{source_id}: checksum-set member must use POSIX separators"
            )
        posix_rel = PurePosixPath(raw_path)
        normalized = posix_rel.as_posix()
        if (
            posix_rel.is_absolute()
            or not posix_rel.parts
            or ".." in posix_rel.parts
            or raw_path != normalized
        ):
            raise VaultGateError(
                f"{source_id}: unsafe checksum-set member path {raw_path!r}"
            )
        rel = Path(*posix_rel.parts)
        if normalized in seen_paths:
            raise VaultGateError(
                f"{source_id}: duplicate checksum-set member {normalized}"
            )
        seen_paths.add(normalized)

        member = artifact.parent / rel
        if member.is_symlink():
            raise VaultGateError(
                f"{source_id}: checksum-set member must not be a symlink: {normalized}"
            )
        if not member.is_file():
            raise VaultGateError(
                f"{source_id}: missing checksum-set member {normalized}"
            )
        try:
            resolved = member.resolve()
            resolved.relative_to(snapshot_root)
        except ValueError as exc:
            raise VaultGateError(
                f"{source_id}: checksum-set member resolves outside snapshot root"
            ) from exc
        if resolved == artifact.resolve():
            raise VaultGateError(
                f"{source_id}: checksum-set artifact cannot include itself"
            )
        if resolved in seen_targets:
            raise VaultGateError(
                f"{source_id}: checksum-set aliases the same file more than once"
            )
        seen_targets.add(resolved)

        if sha256_file(member) != expected_hash:
            raise VaultGateError(
                f"{source_id}: checksum-set member SHA-256 mismatch: {normalized}"
            )

    return len(lines)


def validate_registry(registry_path: Path) -> None:
    registry_path = registry_path.resolve()
    if registry_path.parent.name != "source-vault":
        raise VaultGateError("Registry must live directly under source-vault/")

    root = registry_path.parents[1]
    _load_policy(root)

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

        artifact_kind = source.get("artifact_kind", "file")
        if artifact_kind not in ALLOWED_ARTIFACT_KINDS:
            raise VaultGateError(
                f"{source_id}: invalid artifact_kind {artifact_kind!r}"
            )

        snapshot_fields_present = [
            field
            for field in PRESERVED_SNAPSHOT_FIELDS
            if source.get(field) not in (None, "")
        ]
        release_requirements = _validate_release_requirements(source, source_id)
        retention_status = (
            release_requirements.get("historical_snapshot_retention_status")
            if release_requirements is not None
            else None
        )
        retention_required = (
            status in {"awaiting-artifact", "production-approved"}
            or bool(snapshot_fields_present)
        )
        if retention_required and retention_status != "verified-allowed":
            raise VaultGateError(
                f"{source_id}: source requires verified historical "
                "snapshot retention permission before capture or preservation"
            )
        if retention_status == "unresolved" and status != "awaiting-licence":
            raise VaultGateError(
                f"{source_id}: unresolved historical snapshot retention "
                "requires status 'awaiting-licence'"
            )
        if retention_status == "verified-not-allowed" and status != "rejected":
            raise VaultGateError(
                f"{source_id}: denied historical snapshot retention "
                "requires status 'rejected'"
            )
        if status == "awaiting-licence" and snapshot_fields_present:
            raise VaultGateError(
                f"{source_id}: awaiting-licence source must not preserve "
                "project-controlled snapshot bytes"
            )
        if status != "production-approved" and not snapshot_fields_present:
            continue

        missing_snapshot_fields = [
            field
            for field in PRESERVED_SNAPSHOT_FIELDS
            if source.get(field) in (None, "")
        ]
        if missing_snapshot_fields:
            raise VaultGateError(
                f"{source_id}: preserved snapshot metadata is incomplete; "
                f"missing {missing_snapshot_fields}"
            )

        for field in ("source_name", "version", "licence_id"):
            if not isinstance(source.get(field), str) or not source[field]:
                raise VaultGateError(
                    f"{source_id}: missing preserved source metadata {field}"
                )

        original_url = source.get("original_url")
        parsed_url = urlparse(original_url) if isinstance(original_url, str) else None
        if (
            parsed_url is None
            or parsed_url.scheme != "https"
            or not parsed_url.netloc
        ):
            raise VaultGateError(
                f"{source_id}: preserved original_url must be an absolute https URL"
            )

        if source.get("redistribution_allowed") is not True:
            raise VaultGateError(
                f"{source_id}: preserved source lacks verified redistribution permission"
            )
        if (
            status == "production-approved"
            and source.get("commercial_use_allowed") is not True
        ):
            raise VaultGateError(
                f"{source_id}: production source lacks verified commercial-use permission"
            )
        if not isinstance(source.get("modification_allowed"), bool):
            raise VaultGateError(
                f"{source_id}: modification_allowed must be explicit"
            )
        if not isinstance(source.get("attribution_required"), bool):
            raise VaultGateError(
                f"{source_id}: attribution_required must be explicit"
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
        if (
            not isinstance(expected_size, int)
            or isinstance(expected_size, bool)
            or expected_size < 1
        ):
            raise VaultGateError(f"{source_id}: invalid byte_size")

        expected_hash = _lower_sha256(
            source.get("sha256"), source_id, "sha256"
        )
        expected_licence_hash = _lower_sha256(
            source.get("licence_sha256"), source_id, "licence_sha256"
        )
        expected_provenance_hash = _lower_sha256(
            source.get("provenance_sha256"), source_id, "provenance_sha256"
        )

        if artifact.stat().st_size != expected_size:
            raise VaultGateError(f"{source_id}: artifact byte_size mismatch")
        if sha256_file(artifact) != expected_hash:
            raise VaultGateError(f"{source_id}: artifact SHA-256 mismatch")
        if artifact_kind == "sha256-set":
            _validate_checksum_set(artifact, source_id)
        if sha256_file(licence) != expected_licence_hash:
            raise VaultGateError(
                f"{source_id}: licence snapshot SHA-256 mismatch"
            )
        if sha256_file(provenance_path) != expected_provenance_hash:
            raise VaultGateError(f"{source_id}: provenance SHA-256 mismatch")

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
            "modification_allowed",
            "attribution_required",
            "licence_snapshot",
            "project_mirror",
        ]
        if artifact_kind != "file":
            required.append("artifact_kind")
        missing = [key for key in required if provenance.get(key) in (None, "")]
        if missing:
            raise VaultGateError(f"{source_id}: provenance missing {missing}")

        _parse_retrieved_at(provenance["retrieved_at"], source_id)

        expected_provenance = {
            "source_id": source_id,
            "source_name": source["source_name"],
            "original_url": source["original_url"],
            "version": source["version"],
            "sha256": expected_hash,
            "byte_size": expected_size,
            "licence_id": source["licence_id"],
            "redistribution_allowed": True,
            "modification_allowed": source["modification_allowed"],
            "attribution_required": source["attribution_required"],
            "licence_snapshot": source["licence_snapshot"],
            "project_mirror": source["vault_artifact"],
        }
        if artifact_kind != "file":
            expected_provenance["artifact_kind"] = artifact_kind
        mismatched = [
            key
            for key, expected in expected_provenance.items()
            if provenance.get(key) != expected
        ]
        if mismatched:
            raise VaultGateError(
                f"{source_id}: provenance does not match registry for {mismatched}"
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
