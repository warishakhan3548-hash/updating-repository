#!/usr/bin/env python3
"""Fail-closed promotion gate for immutable runtime content packs."""
from __future__ import annotations

from contextlib import closing
from datetime import datetime
import hashlib
import json
import sqlite3
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.pack_signatures import (
    PackSignatureError,
    load_strict_json_file,
    validate_trusted_key_policy,
    verify_approved_manifest,
)
from tools.verify_quran_core_pack import (
    QuranPackSemanticError,
    verify_quran_core_pack,
)


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
    try:
        registry = load_strict_json_file(
            registry_path,
            label="source registry",
        )
    except PackSignatureError as exc:
        raise PackGateError(f"invalid source registry JSON: {exc}") from exc
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



def _validate_source_release_review(
    manifest: dict,
    source: dict,
    manifest_path: Path,
) -> None:
    requirements = source.get("release_requirements")
    if requirements is None:
        return
    required_requirement_fields = {
        "latest_upstream_version_required",
        "version_check_url",
        "historical_snapshot_retention_status",
    }
    if (
        not isinstance(requirements, dict)
        or set(requirements) != required_requirement_fields
        or requirements.get("latest_upstream_version_required") is not True
    ):
        raise PackGateError(
            f"{manifest_path}: invalid Source Vault release_requirements"
        )
    retention_status = requirements.get("historical_snapshot_retention_status")
    if retention_status != "verified-allowed":
        raise PackGateError(
            f"{manifest_path}: source lacks verified historical snapshot retention permission"
        )
    version_check_url = requirements.get("version_check_url")
    if not isinstance(version_check_url, str) or not version_check_url.startswith("https://"):
        raise PackGateError(
            f"{manifest_path}: invalid Source Vault release version_check_url"
        )

    review = manifest.get("source_release_review")
    if review is None:
        if manifest.get("review_status") == "approved":
            raise PackGateError(
                f"{manifest_path}: approved pack source requires source_release_review "
                "confirming the latest upstream version"
            )
        return

    required_review_fields = {
        "source_id",
        "source_version",
        "observed_upstream_version",
        "version_check_url",
        "checked_at",
        "licence_sha256",
        "latest_upstream_version_confirmed",
    }
    if not isinstance(review, dict) or set(review) != required_review_fields:
        raise PackGateError(
            f"{manifest_path}: source_release_review has unexpected or missing fields"
        )
    licence_hash = _lower_sha256(
        source.get("licence_sha256"), "registry licence_sha256"
    )
    expected = {
        "source_id": source.get("source_id"),
        "source_version": source.get("version"),
        "observed_upstream_version": source.get("version"),
        "version_check_url": version_check_url,
        "licence_sha256": licence_hash,
        "latest_upstream_version_confirmed": True,
    }
    mismatched = [
        field for field, value in expected.items()
        if review.get(field) != value
    ]
    if mismatched:
        raise PackGateError(
            f"{manifest_path}: source_release_review does not match Source Vault "
            f"for {mismatched}"
        )
    checked_at = review.get("checked_at")
    if not isinstance(checked_at, str) or not checked_at:
        raise PackGateError(f"{manifest_path}: source_release_review checked_at missing")
    try:
        parsed = datetime.fromisoformat(checked_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise PackGateError(
            f"{manifest_path}: source_release_review checked_at is not ISO-8601"
        ) from exc
    if parsed.tzinfo is None:
        raise PackGateError(
            f"{manifest_path}: source_release_review checked_at must include a timezone"
        )


def _validate_canonical_binding(
    root: Path,
    manifest: dict,
    manifest_path: Path,
    pack_metadata: dict[str, str],
) -> None:
    canonical = manifest.get("canonical")
    if not isinstance(canonical, dict):
        raise PackGateError(f"{manifest_path}: schema v3 requires canonical binding")

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

    try:
        canonical_manifest = load_strict_json_file(
            canonical_manifest_path,
            label="canonical manifest",
        )
    except PackSignatureError as exc:
        raise PackGateError(f"{manifest_path}: invalid canonical manifest: {exc}") from exc

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
        "source_url": manifest.get("source_url"),
        "source_licence_sha256": manifest.get("source_licence_sha256"),
        "source_provenance_sha256": manifest.get("source_provenance_sha256"),
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
        raise PackGateError(f"{manifest_path}: schema v3 requires build_toolchain")
    for field in ("python_implementation", "python_version", "sqlite_version"):
        if not isinstance(toolchain.get(field), str) or not toolchain[field]:
            raise PackGateError(f"{manifest_path}: invalid build_toolchain.{field}")

    scope = manifest.get("byte_reproducibility_scope")
    if not isinstance(scope, str) or not scope.strip():
        raise PackGateError(f"{manifest_path}: missing byte_reproducibility_scope")

    expected_metadata = {
        "content_schema_version": str(manifest["content_schema_version"]),
        "canonical_id": canonical["canonical_id"],
        "canonical_version": canonical["canonical_version"],
        "canonical_sha256": canonical["artifact_sha256"],
        "canonical_generator_version": canonical["generator_version"],
    }
    mismatched = [
        key
        for key, value in expected_metadata.items()
        if pack_metadata.get(key) != value
    ]
    if mismatched:
        raise PackGateError(
            f"{manifest_path}: embedded canonical metadata mismatch: {mismatched}"
        )

def validate_manifest(manifest_path: Path, registry_path: Path) -> None:
    root, sources = _load_sources(registry_path)
    manifest_path = manifest_path.resolve()
    try:
        manifest_path.relative_to(root / "content-packs")
    except ValueError as exc:
        raise PackGateError("manifest must be under content-packs/") from exc

    try:
        manifest = load_strict_json_file(
            manifest_path,
            label="pack manifest",
        )
    except PackSignatureError as exc:
        raise PackGateError(f"{manifest_path}: invalid manifest JSON: {exc}") from exc
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
    if manifest["schema_version"] not in {1, 2, 3}:
        raise PackGateError(f"{manifest_path}: unsupported schema_version")
    if manifest["schema_version"] in {2, 3}:
        required_v2 = [
            "source_url",
            "source_attribution",
            "source_licence_url",
            "source_licence_sha256",
            "source_provenance_sha256",
            "notice_path",
            "notice_sha256",
        ]
        missing_v2 = [key for key in required_v2 if manifest.get(key) in (None, "")]
        if missing_v2:
            raise PackGateError(f"{manifest_path}: missing schema v2+ fields {missing_v2}")
    if manifest["schema_version"] == 3:
        required_v3 = [
            "content_schema_version",
            "canonical",
            "build_toolchain",
            "byte_reproducibility_scope",
        ]
        missing_v3 = [key for key in required_v3 if manifest.get(key) in (None, "")]
        if missing_v3:
            raise PackGateError(f"{manifest_path}: missing schema v3 fields {missing_v3}")
        if not isinstance(manifest["content_schema_version"], int) or manifest["content_schema_version"] < 1:
            raise PackGateError(f"{manifest_path}: invalid content_schema_version")
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
    if source.get("commercial_use_allowed") is not True:
        raise PackGateError(
            f"{manifest_path}: source {source_id} lacks commercial-use approval"
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
    _validate_source_release_review(manifest, source, manifest_path)

    if manifest["schema_version"] in {2, 3}:
        source_licence_hash = _lower_sha256(
            source.get("licence_sha256"), "registry licence_sha256"
        )
        source_provenance_hash = _lower_sha256(
            source.get("provenance_sha256"), "registry provenance_sha256"
        )
        provenance_path = _safe_repo_file(
            root, source.get("provenance"), "source provenance", "source-vault"
        )
        try:
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise PackGateError(f"{manifest_path}: invalid source provenance") from exc

        expected_v2 = {
            "source_url": source.get("original_url"),
            "source_attribution": provenance.get("attribution"),
            "source_licence_url": provenance.get("licence_url"),
            "source_licence_sha256": source_licence_hash,
            "source_provenance_sha256": source_provenance_hash,
        }
        for field, value in expected_v2.items():
            if not isinstance(value, str) or not value:
                raise PackGateError(
                    f"{manifest_path}: Source Vault lacks required schema v2 {field}"
                )
            if manifest[field] != value:
                raise PackGateError(
                    f"{manifest_path}: {field} does not match Source Vault provenance"
                )

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
        notice = _safe_repo_file(
            root, notice_path, "notice_path", "content-packs"
        )
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

    if manifest["schema_version"] in {2, 3}:
        try:
            notice_text = notice.read_text(encoding="utf-8")
            uri = f"file:{artifact.as_posix()}?mode=ro"
            with closing(sqlite3.connect(uri, uri=True)) as connection:
                pack_metadata = dict(
                    connection.execute("SELECT key, value FROM pack_metadata").fetchall()
                )
        except (UnicodeDecodeError, sqlite3.Error) as exc:
            raise PackGateError(
                f"{manifest_path}: invalid schema v2 embedded metadata"
            ) from exc

        expected_metadata = {
            "pack_id": manifest["pack_id"],
            "schema_version": str(manifest["schema_version"]),
            "content_version": manifest["content_version"],
            "source_id": source_id,
            "source_version": source["version"],
            "source_sha256": source["sha256"],
            "source_url": manifest["source_url"],
            "source_attribution": manifest["source_attribution"],
            "source_licence_url": manifest["source_licence_url"],
            "source_licence_sha256": manifest["source_licence_sha256"],
            "source_provenance_sha256": manifest["source_provenance_sha256"],
            "source_notice_sha256": manifest["notice_sha256"],
            "source_notice": notice_text,
        }
        mismatched = [
            key
            for key, value in expected_metadata.items()
            if pack_metadata.get(key) != value
        ]
        if mismatched:
            raise PackGateError(
                f"{manifest_path}: embedded pack metadata mismatch: {mismatched}"
            )
        if manifest["schema_version"] == 3:
            _validate_canonical_binding(
                root,
                manifest,
                manifest_path,
                pack_metadata,
            )

    signature = manifest["signature"]
    if not isinstance(signature, dict):
        raise PackGateError(f"{manifest_path}: signature must be an object")
    if manifest["review_status"] == "approved":
        try:
            verify_approved_manifest(
                manifest,
                root / "policy" / "trusted_pack_keys.json",
            )
        except PackSignatureError as exc:
            raise PackGateError(
                f"{manifest_path}: approved pack signature verification failed: {exc}"
            ) from exc

    if manifest["pack_id"] == "quran-core" and manifest["schema_version"] in {2, 3}:
        try:
            verify_quran_core_pack(root, manifest, artifact)
        except QuranPackSemanticError as exc:
            raise PackGateError(
                f"{manifest_path}: Quran semantic verification failed: {exc}"
            ) from exc


def validate_all(registry_path: Path) -> int:
    root, _ = _load_sources(registry_path)
    try:
        validate_trusted_key_policy(
            root / "policy" / "trusted_pack_keys.json"
        )
    except PackSignatureError as exc:
        raise PackGateError(
            f"invalid trusted pack key policy: {exc}"
        ) from exc
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
