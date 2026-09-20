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

## Multi-file snapshot contract

Some trustworthy upstream sources are naturally a set of exact files rather than one blob. Do not concatenate or normalize those source bytes merely to satisfy a single-file preservation model.

Registry entries may use `artifact_kind: "sha256-set"`. In that mode, `vault_artifact` points to an immutable UTF-8 checksum ledger under the snapshot directory. Every ledger member is verified individually by exact SHA-256 and must stay inside that directory. Path traversal, absolute paths, non-POSIX paths, duplicate members, symlink escape, aliases and self-reference fail closed. The checksum ledger itself, licence snapshot and provenance remain independently hash-bound by the registry.

This mechanism does not promote a candidate or settle copyright. Production builders still require explicit `production-approved` status and every source-specific licence/release obligation.

The preserved QuranEnc `arabic_seraj` v1.0.0 review snapshot is additionally checked by `tools/verify_quranenc_snapshot.py`, which validates its exact 119-member checksum set, source/provenance metadata, API manifest, 114 Surah files and 6,236 ordered coordinates without network access. It remains outside production while historical archival-retention permission is unresolved.


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
