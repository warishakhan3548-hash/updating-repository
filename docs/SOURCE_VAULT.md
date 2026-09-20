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

Because this repository is project-controlled redistribution infrastructure, a preserved public snapshot must also have verified redistribution permission and explicit modification/attribution flags. If those rights are unresolved, keep the source metadata-only and do not mirror its bytes.

Acquisition tools that write into `source-vault/` must consult the registry **before making any network request**. A source in `awaiting-licence` is not capture-authorized. This prevents a review-only downloader from accidentally turning unresolved third-party rights into a public project-controlled mirror.

## Production promotion contract

A `production-approved` registry entry fails closed unless the project has a consistent source identity, verified redistribution permission, explicit modification/attribution flags, a project-controlled artifact, a non-empty licence snapshot and provenance file, and hashes that still match all three preserved files.

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

## Existing review-only legal hold

The already-preserved QuranEnc `arabic_seraj` v1.0.0 directory is a review-only exception created before the registry was reclassified. It is not referenced by the registry's production artifact/provenance fields and must not feed a content pack. Its continued public retention, or any future version capture, is part of the unresolved archival-rights review. This exception does not weaken the forward acquisition rule: an `awaiting-licence` source is not capture-authorized.
