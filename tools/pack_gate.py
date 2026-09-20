#!/usr/bin/env python3
"""Fail-closed promotion gate for immutable runtime content packs."""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path


class PackGateError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _lower_sha256(value: object, field: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(ch not in "0123456789abcdef" for ch in value)
    ):
        raise PackGateError(f"invalid {field}")
    return value


def _safe_repo_file(root: Path, raw: object, field: str, prefix: str) -> Path:
    if not isinstance(raw, str) or not raw:
        raise PackGateError(f"missing {field}")
    rel = Path(raw)
    if rel.is_absolute() or ".." in rel.parts or not rel.parts or rel.parts[0] != prefix:
        raise PackGateError(f"{field} must be under {prefix}/")
    path = root / rel
    if not path.is_file():
        raise PackGateError(f"missing {field}: {rel}")
    allowed_root = (root / prefix).resolve()
    try:
        path.resolve().relative_to(allowed_root)
    except ValueError as exc:
        raise PackGateError(f"{field} resolves outside {prefix}/") from exc
    return path


def _load_sources(registry_path: Path) -> tuple[Path, dict[str, dict]]:
    registry_path = registry_path.resolve()
    root = registry_path.parents[1]
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    if registry.get("schema_version") != 1:
        raise PackGateError("unsupported source registry schema_version")
    sources = registry.get("sources")
    if not isinstance(sources, list):
        raise PackGateError("source registry sources must be a list")
    by_id: dict[str, dict] = {}
    for source in sources:
        source_id = source.get("source_id") if isinstance(source, dict) else None
        if not isinstance(source_id, str) or not source_id or source_id in by_id:
            raise PackGateError(f"invalid or duplicate source_id: {source_id!r}")
        by_id[source_id] = source
    return root, by_id


def _validate_canonical_binding(
    root: Path,
    manifest: dict,
    manifest_path: Path,
) -> None:
    canonical = manifest.get("canonical")
    if not isinstance(canonical, dict):
        raise PackGateError(f"{manifest_path}: schema v2 requires canonical binding")

    required = (
        "canonical_id",
        "canonical_version",
        "generator_version",
        "manifest_path",
        "manifest_sha256",
        "artifact_path",
        "artifact_sha256",
        "artifact_byte_size",
        "record_count",
    )
    missing = [key for key in required if canonical.get(key) in (None, "")]
    if missing:
        raise PackGateError(f"{manifest_path}: canonical missing {missing}")

    canonical_manifest_path = _safe_repo_file(
        root, canonical["manifest_path"], "canonical.manifest_path", "canonical"
    )
    canonical_manifest_hash = _lower_sha256(
        canonical["manifest_sha256"], "canonical.manifest_sha256"
    )
    if sha256_file(canonical_manifest_path) != canonical_manifest_hash:
        raise PackGateError(f"{manifest_path}: canonical manifest SHA-256 mismatch")

    canonical_manifest = json.loads(canonical_manifest_path.read_text(encoding="utf-8"))
    artifact = _safe_repo_file(
        root, canonical["artifact_path"], "canonical.artifact_path", "canonical"
    )
    if artifact.resolve().parent != canonical_manifest_path.parent:
        raise PackGateError(
            f"{manifest_path}: canonical artifact must resolve inside its manifest directory"
        )
    artifact_hash = _lower_sha256(
        canonical["artifact_sha256"], "canonical.artifact_sha256"
    )
    artifact_size = canonical["artifact_byte_size"]
    if not isinstance(artifact_size, int) or artifact_size < 1:
        raise PackGateError(f"{manifest_path}: invalid canonical artifact_byte_size")
    if artifact.stat().st_size != artifact_size:
        raise PackGateError(f"{manifest_path}: canonical artifact byte-size mismatch")
    if sha256_file(artifact) != artifact_hash:
        raise PackGateError(f"{manifest_path}: canonical artifact SHA-256 mismatch")

    expected = {
        "canonical_id": canonical.get("canonical_id"),
        "canonical_version": canonical.get("canonical_version"),
        "generator_version": canonical.get("generator_version"),
        "artifact_path": canonical.get("artifact_path"),
        "artifact_sha256": canonical.get("artifact_sha256"),
        "artifact_byte_size": canonical.get("artifact_byte_size"),
        "record_count": canonical.get("record_count"),
        "source_id": manifest.get("source_id"),
        "source_name": manifest.get("source_name"),
        "source_version": manifest.get("source_version"),
        "source_vault_path": manifest.get("source_vault_path"),
        "source_sha256": manifest.get("source_sha256"),
        "licence": manifest.get("licence"),
    }
    for field, value in expected.items():
        if canonical_manifest.get(field) != value:
            raise PackGateError(
                f"{manifest_path}: canonical manifest {field} does not match pack/source binding"
            )

    if canonical.get("record_count") != manifest.get("record_count"):
        raise PackGateError(f"{manifest_path}: canonical record_count mismatch")

    toolchain = manifest.get("build_toolchain")
    if not isinstance(toolchain, dict):
        raise PackGateError(f"{manifest_path}: schema v2 requires build_toolchain")
    for field in ("python_implementation", "python_version", "sqlite_version"):
        if not isinstance(toolchain.get(field), str) or not toolchain[field]:
            raise PackGateError(f"{manifest_path}: invalid build_toolchain.{field}")

    scope = manifest.get("byte_reproducibility_scope")
    if not isinstance(scope, str) or not scope.strip():
        raise PackGateError(f"{manifest_path}: missing byte_reproducibility_scope")


def validate_manifest(manifest_path: Path, registry_path: Path) -> None:
    root, sources = _load_sources(registry_path)
    manifest_path = manifest_path.resolve()
    try:
        manifest_path.relative_to(root / "content-packs")
    except ValueError as exc:
        raise PackGateError("manifest must be under content-packs/") from exc

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    required = [
        "pack_id",
        "schema_version",
        "content_version",
        "source_id",
        "source_name",
        "source_version",
        "source_vault_path",
        "source_sha256",
        "licence",
        "importer_version",
        "artifact_path",
        "record_count",
        "review_status",
        "built_sha256",
        "built_byte_size",
        "dependencies",
        "signature",
    ]
    missing = [key for key in required if manifest.get(key) in (None, "")]
    if missing:
        raise PackGateError(f"{manifest_path}: missing {missing}")
    if manifest["schema_version"] not in {1, 2}:
        raise PackGateError(f"{manifest_path}: unsupported schema_version")
    if not isinstance(manifest["record_count"], int) or manifest["record_count"] < 0:
        raise PackGateError(f"{manifest_path}: invalid record_count")
    if manifest["review_status"] not in {"candidate", "reviewed", "approved"}:
        raise PackGateError(f"{manifest_path}: invalid review_status")
    if not isinstance(manifest["dependencies"], list) or any(
        not isinstance(dep, str) or not dep for dep in manifest["dependencies"]
    ):
        raise PackGateError(f"{manifest_path}: invalid dependencies")
    if len(set(manifest["dependencies"])) != len(manifest["dependencies"]):
        raise PackGateError(f"{manifest_path}: duplicate dependencies")
    if manifest["pack_id"] in manifest["dependencies"]:
        raise PackGateError(f"{manifest_path}: pack cannot depend on itself")

    source_id = manifest["source_id"]
    source = sources.get(source_id)
    if source is None:
        raise PackGateError(f"{manifest_path}: unknown source_id {source_id}")
    if source.get("status") != "production-approved":
        raise PackGateError(
            f"{manifest_path}: source {source_id} is not production-approved"
        )
    if source.get("redistribution_allowed") is not True:
        raise PackGateError(
            f"{manifest_path}: source {source_id} lacks redistribution approval"
        )

    expected = {
        "source_name": source.get("source_name"),
        "source_version": source.get("version"),
        "source_vault_path": source.get("vault_artifact"),
        "source_sha256": source.get("sha256"),
        "licence": source.get("licence_id"),
    }
    for field, value in expected.items():
        if manifest[field] != value:
            raise PackGateError(f"{manifest_path}: {field} does not match Source Vault")
    _lower_sha256(manifest["source_sha256"], "source_sha256")

    notice_path = manifest.get("notice_path")
    notice_sha256 = manifest.get("notice_sha256")
    notice_path_missing = notice_path in (None, "")
    notice_sha_missing = notice_sha256 in (None, "")

    if source.get("attribution_required") is True and (
        notice_path_missing or notice_sha_missing
    ):
        raise PackGateError(
            f"{manifest_path}: attribution-required source needs notice_path and notice_sha256"
        )
    if notice_path_missing != notice_sha_missing:
        raise PackGateError(
            f"{manifest_path}: notice_path and notice_sha256 must be provided together"
        )
    if not notice_path_missing:
        notice_hash = _lower_sha256(notice_sha256, "notice_sha256")
        notice = _safe_repo_file(root, notice_path, "notice_path", "content-packs")
        if notice.resolve().parent != manifest_path.parent:
            raise PackGateError(
                f"{manifest_path}: notice_path must resolve inside manifest pack directory"
            )
        if notice.stat().st_size < 1:
            raise PackGateError(f"{manifest_path}: attribution notice is empty")
        if sha256_file(notice) != notice_hash:
            raise PackGateError(f"{manifest_path}: notice_sha256 mismatch")

    artifact = _safe_repo_file(root, manifest["artifact_path"], "artifact_path", "content-packs")
    if artifact.resolve().parent != manifest_path.parent:
        raise PackGateError(
            f"{manifest_path}: artifact_path must resolve inside manifest pack directory"
        )
    expected_hash = _lower_sha256(manifest["built_sha256"], "built_sha256")
    expected_size = manifest["built_byte_size"]
    if not isinstance(expected_size, int) or expected_size < 1:
        raise PackGateError(f"{manifest_path}: invalid built_byte_size")
    if artifact.stat().st_size != expected_size:
        raise PackGateError(f"{manifest_path}: built_byte_size mismatch")
    if sha256_file(artifact) != expected_hash:
        raise PackGateError(f"{manifest_path}: built_sha256 mismatch")

    if manifest["schema_version"] == 2:
        _validate_canonical_binding(root, manifest, manifest_path)

    signature = manifest["signature"]
    if not isinstance(signature, dict):
        raise PackGateError(f"{manifest_path}: signature must be an object")
    if manifest["review_status"] == "approved":
        required_signature = ("algorithm", "key_id", "value")
        if any(
            not isinstance(signature.get(key), str) or not signature[key]
            for key in required_signature
        ):
            raise PackGateError(
                f"{manifest_path}: approved pack requires signature algorithm/key_id/value"
            )


def validate_all(registry_path: Path) -> int:
    root, _ = _load_sources(registry_path)
    manifests = sorted((root / "content-packs").glob("**/manifest.json"))
    for manifest in manifests:
        validate_manifest(manifest, registry_path)
    return len(manifests)


if __name__ == "__main__":
    try:
        registry = Path(sys.argv[1] if len(sys.argv) > 1 else "source-vault/registry.json")
        if len(sys.argv) > 2:
            count = 0
            for raw in sys.argv[2:]:
                validate_manifest(Path(raw), registry)
                count += 1
        else:
            count = validate_all(registry)
    except (OSError, ValueError, json.JSONDecodeError, PackGateError) as exc:
        print(f"Content pack gate FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
    print(f"Content pack gate OK ({count} manifest(s))")
