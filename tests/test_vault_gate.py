import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from tools.vault_gate import VaultGateError, validate_registry


class VaultGateTests(unittest.TestCase):
    def _policy(self, root: Path, **overrides: bool) -> None:
        policy_dir = root / "policy"
        policy_dir.mkdir(parents=True, exist_ok=True)
        rules = {
            "require_production_approved": True,
            "require_redistribution_allowed": True,
            "require_commercial_use_allowed": True,
            "require_historical_snapshot_retention_allowed": True,
            "require_exact_sha256": True,
            "require_licence_snapshot": True,
            "require_project_controlled_artifact": True,
            "forbid_runtime_upstream_download": True,
            "forbid_unknown_licence_in_release": True,
        }
        rules.update(overrides)
        (policy_dir / "license_policy.json").write_text(
            json.dumps({"schema_version": 1, "release_rules": rules}),
            encoding="utf-8",
        )

    def _refresh_provenance_hash(
        self, registry_path: Path, provenance_path: Path
    ) -> None:
        data = json.loads(registry_path.read_text(encoding="utf-8"))
        data["sources"][0]["provenance_sha256"] = hashlib.sha256(
            provenance_path.read_bytes()
        ).hexdigest()
        registry_path.write_text(json.dumps(data), encoding="utf-8")

    def _registry(self, root: Path, source: dict) -> Path:
        self._policy(root)
        vault = root / "source-vault"
        vault.mkdir(parents=True, exist_ok=True)
        path = vault / "registry.json"
        path.write_text(
            json.dumps({"schema_version": 1, "sources": [source]}),
            encoding="utf-8",
        )
        return path

    def _valid_snapshot(
        self, root: Path, *, status: str = "production-approved"
    ):
        base = root / "source-vault" / "quran" / "example" / "1.0"
        (base / "raw").mkdir(parents=True)
        artifact = base / "raw" / "source.txt"
        artifact.write_bytes(b"immutable example")
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        licence = base / "LICENSE.txt"
        licence.write_text("example licence", encoding="utf-8")
        provenance = {
            "source_id": "example",
            "source_name": "Example Source",
            "original_url": "https://example.invalid/source",
            "version": "1.0",
            "retrieved_at": "2026-09-20T00:00:00Z",
            "sha256": digest,
            "byte_size": artifact.stat().st_size,
            "licence_id": "example-licence",
            "redistribution_allowed": True,
            "commercial_use_allowed": True,
            "modification_allowed": False,
            "attribution_required": True,
            "licence_snapshot": "source-vault/quran/example/1.0/LICENSE.txt",
            "project_mirror": "source-vault/quran/example/1.0/raw/source.txt",
        }
        provenance_path = base / "provenance.json"
        provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
        source = {
            "source_id": "example",
            "source_name": "Example Source",
            "original_url": "https://example.invalid/source",
            "version": "1.0",
            "status": status,
            "redistribution_allowed": True,
            "commercial_use_allowed": True,
            "modification_allowed": False,
            "attribution_required": True,
            "licence_id": "example-licence",
            "vault_artifact": "source-vault/quran/example/1.0/raw/source.txt",
            "licence_snapshot": "source-vault/quran/example/1.0/LICENSE.txt",
            "provenance": "source-vault/quran/example/1.0/provenance.json",
            "sha256": digest,
            "licence_sha256": hashlib.sha256(licence.read_bytes()).hexdigest(),
            "provenance_sha256": hashlib.sha256(
                provenance_path.read_bytes()
            ).hexdigest(),
            "byte_size": artifact.stat().st_size,
            "release_requirements": {
                "latest_upstream_version_required": False,
                "version_check_url": "https://example.invalid/versions",
                "historical_snapshot_retention_status": "verified-allowed",
            },
        }
        return source, artifact, provenance_path

    def _valid_checksum_set(
        self, root: Path, *, status: str = "research-candidate"
    ):
        base = root / "source-vault" / "quran-gloss" / "example" / "1.0"
        raw = base / "raw"
        raw.mkdir(parents=True)
        first = raw / "001.json"
        second = raw / "002.json"
        first.write_bytes(b'{"sura":1}\n')
        second.write_bytes(b'{"sura":2}\n')

        checksum = base / "sha256.txt"
        entries = [
            ("raw/001.json", hashlib.sha256(first.read_bytes()).hexdigest()),
            ("raw/002.json", hashlib.sha256(second.read_bytes()).hexdigest()),
        ]
        checksum.write_text(
            "".join(f"{digest}  {path}\n" for path, digest in entries),
            encoding="utf-8",
        )
        digest = hashlib.sha256(checksum.read_bytes()).hexdigest()

        licence = base / "LICENSE.txt"
        licence.write_text("example multi-file licence", encoding="utf-8")
        provenance = {
            "source_id": "example-multi",
            "source_name": "Example Multi Source",
            "original_url": "https://example.invalid/multi",
            "version": "1.0",
            "retrieved_at": "2026-09-21T00:00:00Z",
            "artifact_kind": "sha256-set",
            "sha256": digest,
            "byte_size": checksum.stat().st_size,
            "licence_id": "example-licence",
            "redistribution_allowed": True,
            "commercial_use_allowed": True,
            "modification_allowed": False,
            "attribution_required": True,
            "licence_snapshot": (
                "source-vault/quran-gloss/example/1.0/LICENSE.txt"
            ),
            "project_mirror": (
                "source-vault/quran-gloss/example/1.0/sha256.txt"
            ),
        }
        provenance_path = base / "provenance.json"
        provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
        source = {
            "source_id": "example-multi",
            "source_name": "Example Multi Source",
            "original_url": "https://example.invalid/multi",
            "version": "1.0",
            "status": status,
            "artifact_kind": "sha256-set",
            "redistribution_allowed": True,
            "commercial_use_allowed": True,
            "modification_allowed": False,
            "attribution_required": True,
            "licence_id": "example-licence",
            "vault_artifact": (
                "source-vault/quran-gloss/example/1.0/sha256.txt"
            ),
            "licence_snapshot": (
                "source-vault/quran-gloss/example/1.0/LICENSE.txt"
            ),
            "provenance": (
                "source-vault/quran-gloss/example/1.0/provenance.json"
            ),
            "sha256": digest,
            "licence_sha256": hashlib.sha256(licence.read_bytes()).hexdigest(),
            "provenance_sha256": hashlib.sha256(
                provenance_path.read_bytes()
            ).hexdigest(),
            "byte_size": checksum.stat().st_size,
            "release_requirements": {
                "latest_upstream_version_required": False,
                "version_check_url": "https://example.invalid/versions",
                "historical_snapshot_retention_status": "verified-allowed",
            },
        }
        return source, first, checksum

    def test_research_candidate_can_remain_unmirrored(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._registry(
                Path(tmp),
                {"source_id": "candidate", "status": "research-candidate"},
            )
            validate_registry(path)

    def test_awaiting_artifact_requires_archival_clearance(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._registry(
                Path(tmp),
                {"source_id": "candidate", "status": "awaiting-artifact"},
            )
            with self.assertRaisesRegex(
                VaultGateError, "verified historical snapshot retention permission"
            ):
                validate_registry(path)

    def test_valid_non_production_preserved_snapshot_is_verified(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, _ = self._valid_snapshot(
                root, status="research-candidate"
            )
            validate_registry(self._registry(root, source))

    def test_valid_non_production_checksum_set_is_verified(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, _ = self._valid_checksum_set(root)
            validate_registry(self._registry(root, source))

    def test_checksum_set_member_tamper_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, first, _ = self._valid_checksum_set(root)
            path = self._registry(root, source)
            first.write_bytes(b'{"sura":999}\n')
            with self.assertRaisesRegex(
                VaultGateError, "checksum-set member SHA-256 mismatch"
            ):
                validate_registry(path)

    def test_checksum_set_member_symlink_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, first, _ = self._valid_checksum_set(root)
            path = self._registry(root, source)
            outside = root / "outside.json"
            outside.write_bytes(first.read_bytes())
            first.unlink()
            first.symlink_to(outside)
            with self.assertRaisesRegex(
                VaultGateError, "checksum-set member must not be a symlink"
            ):
                validate_registry(path)

    def test_invalid_artifact_kind_fails_even_without_mirror(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._registry(
                Path(tmp),
                {
                    "source_id": "candidate",
                    "status": "awaiting-artifact",
                    "artifact_kind": "tarball-magic",
                },
            )
            with self.assertRaisesRegex(VaultGateError, "invalid artifact_kind"):
                validate_registry(path)

    def test_non_production_partial_snapshot_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._registry(
                Path(tmp),
                {
                    "source_id": "candidate",
                    "status": "research-candidate",
                    "vault_artifact": "source-vault/quran/candidate/raw.txt",
                },
            )
            with self.assertRaisesRegex(
                VaultGateError, "preserved snapshot metadata is incomplete"
            ):
                validate_registry(path)

    def test_tampered_non_production_snapshot_fails_hash_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, artifact, _ = self._valid_snapshot(
                root, status="research-candidate"
            )
            path = self._registry(root, source)
            artifact.write_bytes(b"tampered example!")
            with self.assertRaisesRegex(VaultGateError, "artifact SHA-256 mismatch"):
                validate_registry(path)

    def test_production_source_without_mirror_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._registry(
                Path(tmp),
                {
                    "source_id": "bad",
                    "status": "production-approved",
                    "redistribution_allowed": True,
                },
            )
            with self.assertRaises(VaultGateError):
                validate_registry(path)

    def test_valid_production_snapshot_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, _ = self._valid_snapshot(root)
            validate_registry(self._registry(root, source))

    def test_production_source_without_commercial_permission_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, _ = self._valid_snapshot(root)
            source["commercial_use_allowed"] = False
            with self.assertRaisesRegex(
                VaultGateError, "verified commercial-use permission"
            ):
                validate_registry(self._registry(root, source))

    def test_production_source_with_unknown_commercial_permission_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, _ = self._valid_snapshot(root)
            source["commercial_use_allowed"] = None
            with self.assertRaisesRegex(
                VaultGateError, "verified commercial-use permission"
            ):
                validate_registry(self._registry(root, source))

    def test_tampered_artifact_fails_hash_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, artifact, _ = self._valid_snapshot(root)
            path = self._registry(root, source)
            artifact.write_bytes(b"tampered")
            with self.assertRaises(VaultGateError):
                validate_registry(path)

    def test_provenance_version_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, provenance_path = self._valid_snapshot(root)
            path = self._registry(root, source)
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["version"] = "latest"
            provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
            self._refresh_provenance_hash(path, provenance_path)
            with self.assertRaises(VaultGateError):
                validate_registry(path)

    def test_provenance_licence_permissions_must_match_registry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, provenance_path = self._valid_snapshot(root)
            path = self._registry(root, source)
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["modification_allowed"] = True
            provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
            self._refresh_provenance_hash(path, provenance_path)
            with self.assertRaisesRegex(VaultGateError, "provenance does not match registry"):
                validate_registry(path)

    def test_provenance_licence_snapshot_path_must_match_registry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, provenance_path = self._valid_snapshot(root)
            path = self._registry(root, source)
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["licence_snapshot"] = "source-vault/quran/example/1.0/OTHER.txt"
            provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
            self._refresh_provenance_hash(path, provenance_path)
            with self.assertRaisesRegex(VaultGateError, "provenance does not match registry"):
                validate_registry(path)

    def test_project_mirror_must_point_to_pinned_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, provenance_path = self._valid_snapshot(root)
            path = self._registry(root, source)
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["project_mirror"] = "https://upstream.invalid/latest"
            provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
            self._refresh_provenance_hash(path, provenance_path)
            with self.assertRaises(VaultGateError):
                validate_registry(path)


    def test_production_origin_must_be_absolute_https(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, provenance_path = self._valid_snapshot(root)
            source["original_url"] = "http://example.invalid/source"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["original_url"] = source["original_url"]
            provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
            with self.assertRaisesRegex(VaultGateError, "absolute https URL"):
                validate_registry(self._registry(root, source))

    def test_vault_artifact_symlink_cannot_escape_source_vault(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, artifact, _ = self._valid_snapshot(root)
            outside = root / "outside.txt"
            outside.write_bytes(artifact.read_bytes())
            artifact.unlink()
            artifact.symlink_to(outside)
            with self.assertRaisesRegex(VaultGateError, "resolves outside source-vault"):
                validate_registry(self._registry(root, source))


    def test_tampered_licence_snapshot_fails_hash_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, _ = self._valid_snapshot(root)
            path = self._registry(root, source)
            licence = (
                root
                / "source-vault"
                / "quran"
                / "example"
                / "1.0"
                / "LICENSE.txt"
            )
            licence.write_text("changed terms", encoding="utf-8")
            with self.assertRaises(VaultGateError):
                validate_registry(path)

    def test_retrieval_timestamp_requires_timezone(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, provenance_path = self._valid_snapshot(root)
            path = self._registry(root, source)
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["retrieved_at"] = "2026-09-20T00:00:00"
            provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
            self._refresh_provenance_hash(path, provenance_path)
            with self.assertRaises(VaultGateError):
                validate_registry(path)

    def test_weakened_licence_policy_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, _ = self._valid_snapshot(root)
            path = self._registry(root, source)
            self._policy(root, forbid_unknown_licence_in_release=False)
            with self.assertRaises(VaultGateError):
                validate_registry(path)

    def test_latest_version_release_requirement_requires_https_check_url(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._registry(
                Path(tmp),
                {
                    "source_id": "candidate",
                    "status": "awaiting-artifact",
                    "release_requirements": {
                        "latest_upstream_version_required": True,
                        "version_check_url": "http://example.invalid/versions",
                        "historical_snapshot_retention_status": "unresolved",
                    },
                },
            )
            with self.assertRaisesRegex(
                VaultGateError, "version_check_url must be an absolute https URL"
            ):
                validate_registry(path)

    def test_production_source_blocks_unresolved_historical_snapshot_retention(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, _ = self._valid_snapshot(root)
            source["release_requirements"] = {
                "latest_upstream_version_required": True,
                "version_check_url": "https://example.invalid/versions",
                "historical_snapshot_retention_status": "unresolved",
            }
            path = self._registry(root, source)
            with self.assertRaisesRegex(
                VaultGateError, "verified historical snapshot retention permission"
            ):
                validate_registry(path)


    def test_unresolved_historical_retention_requires_awaiting_licence_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._registry(
                Path(tmp),
                {
                    "source_id": "candidate",
                    "status": "research-candidate",
                    "release_requirements": {
                        "latest_upstream_version_required": True,
                        "version_check_url": "https://example.invalid/versions",
                        "historical_snapshot_retention_status": "unresolved",
                    },
                },
            )
            with self.assertRaisesRegex(
                VaultGateError,
                "unresolved historical snapshot retention requires status 'awaiting-licence'",
            ):
                validate_registry(path)

    def test_unresolved_historical_retention_allows_metadata_only_awaiting_licence(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._registry(
                Path(tmp),
                {
                    "source_id": "candidate",
                    "status": "awaiting-licence",
                    "release_requirements": {
                        "latest_upstream_version_required": True,
                        "version_check_url": "https://example.invalid/versions",
                        "historical_snapshot_retention_status": "unresolved",
                    },
                },
            )
            validate_registry(path)

    def test_awaiting_licence_source_cannot_preserve_snapshot_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, _ = self._valid_snapshot(root, status="awaiting-licence")
            path = self._registry(root, source)
            with self.assertRaisesRegex(
                VaultGateError,
                "awaiting-licence source must not preserve project-controlled snapshot bytes",
            ):
                validate_registry(path)


    def test_release_requirements_do_not_mutate_acquisition_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _, provenance_path = self._valid_snapshot(root)
            source["release_requirements"] = {
                "latest_upstream_version_required": True,
                "version_check_url": "https://example.invalid/versions",
                "historical_snapshot_retention_status": "verified-allowed",
            }
            path = self._registry(root, source)
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            self.assertNotIn("release_requirements", provenance)
            validate_registry(path)

    def test_denied_historical_retention_requires_rejected_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._registry(
                Path(tmp),
                {
                    "source_id": "candidate",
                    "status": "awaiting-licence",
                    "release_requirements": {
                        "latest_upstream_version_required": False,
                        "version_check_url": "https://example.invalid/versions",
                        "historical_snapshot_retention_status": "verified-not-allowed",
                    },
                },
            )
            with self.assertRaisesRegex(
                VaultGateError,
                "denied historical snapshot retention requires status 'rejected'",
            ):
                validate_registry(path)

    def test_denied_historical_retention_allows_metadata_only_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._registry(
                Path(tmp),
                {
                    "source_id": "candidate",
                    "status": "rejected",
                    "release_requirements": {
                        "latest_upstream_version_required": False,
                        "version_check_url": "https://example.invalid/versions",
                        "historical_snapshot_retention_status": "verified-not-allowed",
                    },
                },
            )
            validate_registry(path)


if __name__ == "__main__":
    unittest.main()
