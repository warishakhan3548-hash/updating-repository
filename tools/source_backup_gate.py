#!/usr/bin/env python3
"""Validate checksum-bound independent backups for release source artifacts."""
from __future__ import annotations

import sys
from datetime import datetime
from pathlib import Path

from tools.pack_signatures import PackSignatureError, load_strict_json_file

ALLOWED_STATUSES = {"pending", "verified"}
ALLOWED_STORAGE_CLASSES = {
    "independent-cloud",
    "offline-media",
    "institutional-archive",
}


class SourceBackupGateError(RuntimeError):
    pass


def _lower_sha256(value: object, field: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(ch not in "0123456789abcdef" for ch in value)
    ):
        raise SourceBackupGateError(f"invalid lowercase {field}")
    return value


def _parse_verified_at(value: object, source_id: str) -> None:
    if not isinstance(value, str) or not value:
        raise SourceBackupGateError(f"{source_id}: verified backup requires verified_at")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise SourceBackupGateError(
            f"{source_id}: backup verified_at is not ISO-8601"
        ) from exc
    if parsed.tzinfo is None:
        raise SourceBackupGateError(
            f"{source_id}: backup verified_at must include a timezone"
        )


def _load_json(path: Path, label: str) -> dict:
    try:
        value = load_strict_json_file(path, label=label)
    except PackSignatureError as exc:
        raise SourceBackupGateError(str(exc)) from exc
    if not isinstance(value, dict):
        raise SourceBackupGateError(f"{label} must be a JSON object")
    return value


def _load_sources(registry_path: Path) -> tuple[Path, dict[str, dict]]:
    registry_path = registry_path.resolve()
    root = registry_path.parents[1]
    registry = _load_json(registry_path, "source registry")
    if registry.get("schema_version") != 1:
        raise SourceBackupGateError("unsupported source registry schema_version")
    raw_sources = registry.get("sources")
    if not isinstance(raw_sources, list):
        raise SourceBackupGateError("source registry sources must be a list")
    sources: dict[str, dict] = {}
    for item in raw_sources:
        source_id = item.get("source_id") if isinstance(item, dict) else None
        if not isinstance(source_id, str) or not source_id or source_id in sources:
            raise SourceBackupGateError(
                f"invalid or duplicate source registry source_id: {source_id!r}"
            )
        sources[source_id] = item
    return root, sources


def _load_attestations(path: Path, sources: dict[str, dict]) -> dict[str, dict]:
    payload = _load_json(path, "source backup attestations")
    if payload.get("schema_version") != 1:
        raise SourceBackupGateError("unsupported source backup schema_version")
    raw_backups = payload.get("backups")
    if not isinstance(raw_backups, list):
        raise SourceBackupGateError("source backup backups must be a list")

    backups: dict[str, dict] = {}
    expected_fields = {
        "source_id",
        "artifact_sha256",
        "status",
        "provider",
        "storage_class",
        "verified_at",
        "verification_method",
        "notes",
    }
    for item in raw_backups:
        if not isinstance(item, dict) or set(item) != expected_fields:
            raise SourceBackupGateError(
                "source backup entry has unexpected or missing fields"
            )
        source_id = item.get("source_id")
        if not isinstance(source_id, str) or not source_id or source_id in backups:
            raise SourceBackupGateError(
                f"invalid or duplicate backup source_id: {source_id!r}"
            )
        source = sources.get(source_id)
        if source is None:
            raise SourceBackupGateError(
                f"{source_id}: backup attestation references unknown source"
            )

        source_sha = _lower_sha256(source.get("sha256"), f"{source_id} source sha256")
        backup_sha = _lower_sha256(
            item.get("artifact_sha256"), f"{source_id} backup artifact_sha256"
        )
        if backup_sha != source_sha:
            raise SourceBackupGateError(
                f"{source_id}: backup artifact_sha256 does not match Source Vault"
            )

        status = item.get("status")
        if status not in ALLOWED_STATUSES:
            raise SourceBackupGateError(f"{source_id}: invalid backup status")

        if status == "pending":
            for field in (
                "provider",
                "storage_class",
                "verified_at",
                "verification_method",
            ):
                if item.get(field) is not None:
                    raise SourceBackupGateError(
                        f"{source_id}: pending backup must not claim {field}"
                    )
        else:
            provider = item.get("provider")
            if not isinstance(provider, str) or not provider.strip():
                raise SourceBackupGateError(
                    f"{source_id}: verified backup requires provider"
                )
            if item.get("storage_class") not in ALLOWED_STORAGE_CLASSES:
                raise SourceBackupGateError(
                    f"{source_id}: invalid verified backup storage_class"
                )
            if item.get("verification_method") != "sha256":
                raise SourceBackupGateError(
                    f"{source_id}: verified backup must be checked by sha256"
                )
            _parse_verified_at(item.get("verified_at"), source_id)

        notes = item.get("notes")
        if not isinstance(notes, str):
            raise SourceBackupGateError(f"{source_id}: backup notes must be a string")
        backups[source_id] = item

    return backups


def validate_all(
    registry_path: Path,
    backup_path: Path | None = None,
    *,
    require_verified: bool = False,
) -> int:
    root, sources = _load_sources(registry_path)
    path = backup_path or (root / "policy" / "source_backups.json")
    backups = _load_attestations(path, sources)

    production = {
        source_id: source
        for source_id, source in sources.items()
        if source.get("status") == "production-approved"
    }
    missing = sorted(set(production) - set(backups))
    if missing:
        raise SourceBackupGateError(
            "production sources missing backup attestation: " + ", ".join(missing)
        )

    if require_verified:
        pending = sorted(
            source_id
            for source_id in production
            if backups[source_id].get("status") != "verified"
        )
        if pending:
            raise SourceBackupGateError(
                "approved release requires independently verified source backup: "
                + ", ".join(pending)
            )
    return len(production)


def require_verified_backup(
    registry_path: Path,
    source_id: str,
    expected_sha256: str,
) -> None:
    root, sources = _load_sources(registry_path)
    source = sources.get(source_id)
    if source is None:
        raise SourceBackupGateError(f"unknown source_id {source_id}")
    source_sha = _lower_sha256(source.get("sha256"), f"{source_id} source sha256")
    if expected_sha256 != source_sha:
        raise SourceBackupGateError(
            f"{source_id}: release source hash does not match Source Vault"
        )

    backups = _load_attestations(root / "policy" / "source_backups.json", sources)
    backup = backups.get(source_id)
    if backup is None:
        raise SourceBackupGateError(
            f"{source_id}: approved release lacks independent backup attestation"
        )
    if backup.get("status") != "verified":
        raise SourceBackupGateError(
            f"{source_id}: approved release requires independently verified source backup"
        )


if __name__ == "__main__":
    try:
        args = sys.argv[1:]
        require_verified = False
        if "--require-verified" in args:
            args.remove("--require-verified")
            require_verified = True
        registry = Path(args[0] if args else "source-vault/registry.json")
        backup = Path(args[1]) if len(args) > 1 else None
        count = validate_all(
            registry,
            backup,
            require_verified=require_verified,
        )
    except (OSError, ValueError, SourceBackupGateError) as exc:
        print(f"Source backup gate FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
    qualifier = "verified " if require_verified else ""
    print(f"Source backup gate OK ({count} production source(s), {qualifier}policy)")
