# Content Pack Manifest Spec

Content packs are immutable derived artifacts. Their manifest binds runtime bytes back to a legally reviewed, project-controlled Source Vault snapshot.

## Common fields

Every pack manifest includes:

- `pack_id`, `schema_version`, `content_version`;
- `source_id`, `source_name`, `source_version`, `source_vault_path`, `source_sha256`;
- `licence`, `edition`, `importer_version`;
- runtime `artifact_path`, `record_count`, `built_sha256`, `built_byte_size`;
- `review_status`, `dependencies`, and `signature`.

`tools/pack_gate.py` fails closed if a pack points at a source that is not `production-approved`, if source identity drifts from the Source Vault registry, or if runtime bytes no longer match their manifest.

## Schema v1

Schema v1 remains readable so existing historical candidate packs stay auditable. It binds source and runtime bytes, but it does not guarantee a self-contained redistribution notice.

A v1 candidate is never silently rewritten into v2. A stronger contract gets a new immutable content version.

## Schema v2 — self-contained source notice

Schema v2 additionally requires:

- `source_url` and `source_attribution`;
- `source_licence_url`;
- exact `source_licence_sha256` and `source_provenance_sha256`;
- a pack-local `notice_path` and `notice_sha256`.

For SQLite packs, the gate also requires the same source identity, attribution, metadata hashes, notice hash, and exact notice text inside `pack_metadata`. The evidence database therefore remains provenance-aware even when opened directly.

The notice is extracted from the pinned preserved source artifact; the importer does not rewrite its wording. Source-specific tests may impose stronger marker requirements.

## Promotion

- `candidate`: deterministic build output; not release-approved.
- `reviewed`: technically/content reviewed but not yet release-approved.
- `approved`: requires real signature material and must satisfy the current release gate.

Old pack versions remain available for rollback and reproducibility.
