# Source Vault

Raw source bytes are immutable. Normalized models and runtime packs are derived layers.

```
source-vault/
  quran/<source>/<version>/
    raw/<artifact>
    LICENSE.txt
    provenance.json
    sha256.txt
  morphology/<source>/<version>/...
  hadith/<source>/<edition-or-version>/...
  fonts/<source>/<version>/...
  audio-metadata/<source>/<version>/...
```

Never silently replace bytes under an existing version path. A changed upstream file gets a new preserved version even when its filename is unchanged.

The registry in `source-vault/registry.json` is the production gate; directories alone do not imply approval. Normal builds consume the preserved artifact/version, never upstream latest.

## Preservation integrity contract

An unmirrored research candidate may remain metadata-only. Once **any** preserved-snapshot field is populated, the snapshot must be complete: artifact, licence snapshot, provenance, exact byte size, and all three SHA-256 values must be present and internally consistent.

The Source Vault gate validates preserved candidate snapshots before production promotion as well as production-approved snapshots. This prevents research/awaiting-review bytes from drifting silently between acquisition and later review. A preserved candidate still cannot feed a release content builder until its registry status is explicitly promoted to `production-approved`.

Because this repository is project-controlled redistribution infrastructure, a preserved public snapshot must also have verified redistribution permission, verified historical-retention permission, and explicit modification/attribution flags. If any of those rights are unresolved or archival retention is denied, keep the source metadata-only and do not mirror its bytes.

`awaiting-artifact`, any preserved snapshot, and `production-approved` require `release_requirements.historical_snapshot_retention_status=verified-allowed`. The separate `latest_upstream_version_required` boolean controls release-time freshness review and does not grant archival permission.

Acquisition tools that write into `source-vault/` must consult the registry **before making any network request**. A source in `awaiting-licence` is not capture-authorized. This prevents a review-only downloader from accidentally turning unresolved third-party rights into a public project-controlled mirror. The central vault gate independently rejects any `awaiting-licence` entry that already declares preserved snapshot bytes, and any source with `historical_snapshot_retention_status: unresolved` must remain `awaiting-licence`.

`awaiting-artifact` is therefore a strict **capture-ready** state, not merely a note that archival retention looks acceptable. The executable gate requires reviewed source/version/licence metadata, an HTTPS origin, verified redistribution and commercial-use permission, explicit modification/attribution flags, and verified historical retention before that status is valid. This centralizes Gate B so a future acquisition script cannot become safer merely by forgetting one licence dimension.

## Closed-world inventory contract

The vault is now validated as a **closed inventory**, not merely as a list of files the registry happens to mention. After per-source integrity checks, CI recursively inventories `source-vault/` and fails if it finds any unregistered file or any symlink.

Accounted files are limited to:

- the registry and the vault README;
- each preserved source's registered artifact, licence snapshot and provenance;
- members named by a validated `sha256-set` ledger;
- an optional provenance-declared single-file `checksum_file`, which must live beside the artifact and exactly bind that artifact's SHA-256 and filename.

This prevents unresolved/rejected sources, abandoned acquisition output, or accidental copied datasets from hiding bytes inside project-controlled Source Vault storage without passing the same licence, retention, provenance and checksum gates.

## Multi-file snapshot contract

Some legally cleared sources are naturally a versioned set of files rather than one blob. Do not concatenate or rewrite those source bytes merely to satisfy the single-file gate.

Registry entries may set `artifact_kind` to `sha256-set`. In that mode:

- `vault_artifact` points to an immutable UTF-8 checksum ledger under the snapshot directory;
- every ledger line is exactly `<lowercase-sha256><two spaces><relative-posix-path>`;
- every listed member must resolve inside the same snapshot directory;
- absolute/traversal/non-canonical paths, duplicate members, any symlinked ledger/member, self-reference and hash drift fail closed;
- the registry still independently hashes the checksum ledger, licence snapshot and provenance;
- non-production preserved sets remain unusable by release content builders until the registry status is explicitly `production-approved`.

This is an integrity format, not acquisition permission. A source must clear the existing licence/archival gate before bytes are captured or registered. Single-file sources remain the default `artifact_kind=file` contract.

## Production promotion contract

A `production-approved` registry entry fails closed unless the project has a consistent source identity, verified redistribution permission, verified commercial-use permission, verified historical-retention permission, explicit modification/attribution flags, a project-controlled artifact, a non-empty licence snapshot and provenance file, and hashes that still match all three preserved files.

The gate records and verifies:

- artifact SHA-256 and exact byte size;
- licence snapshot SHA-256;
- provenance-file SHA-256;
- source/version/licence/mirror fields cross-checked between registry and provenance;
- redistribution, modification and attribution permissions cross-checked between registry and provenance;
- the archived licence snapshot path cross-checked between registry and provenance;
- a timezone-aware retrieval timestamp;
- mandatory release rules from `policy/license_policy.json`.

`schemas/source_registry_v1.schema.json` documents the registry shape. `tools/vault_gate.py` remains the executable conditional authority for production promotion.
