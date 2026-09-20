# Content Pack Manifest Spec

A runtime content pack is a derived artifact, never the surviving source of truth. Every pack must be traceable to one **production-approved** Source Vault entry.

## Shared contract

Every manifest binds pack identity, content/schema version, source identity/version/path/SHA-256, licence, importer version, runtime artifact path/hash/size, record count, review status, dependencies, and signature metadata.

`tools/pack_gate.py` fails closed when the source is not production-approved, source identity drifts from the Source Vault, or runtime bytes no longer match the manifest.

## Schema v1

Schema v1 remains readable for existing historical packs. For an attribution-required Source Vault entry it requires a pack-local `notice_path` and `notice_sha256`; the notice must be non-empty, remain in the same immutable pack-version directory, and match its declared SHA-256.

Schema v1 does **not** cryptographically bind the notice wording to Source Vault provenance. It must not be silently rewritten in place.

## Schema v2 — provenance-bound redistribution

Schema v2 adds:

- `source_url`;
- `source_attribution`;
- `source_licence_url`;
- exact `source_licence_sha256`;
- exact `source_provenance_sha256`;
- pack-local `notice_path` and `notice_sha256`.

The gate loads the pinned Source Vault provenance and requires these manifest fields to match it. For SQLite packs it then requires the same identity, attribution, licence/provenance hashes, notice hash, and exact notice text inside `pack_metadata`.

This prevents a caller from replacing a legally required notice with arbitrary text and merely recomputing a new notice hash. Source-specific builders may impose stronger rules; the Tanzil builder extracts its notice directly from comment lines in the preserved production artifact.

## Promotion

- `candidate`: deterministic build output; not release-approved.
- `reviewed`: technically/content reviewed but not yet release-approved.
- `approved`: must satisfy current signing and release policy.

Pack content versions are immutable. A stronger trust contract gets a new content version rather than rewriting an existing pack. Previous verified release packs remain available for rollback and reproducibility.
