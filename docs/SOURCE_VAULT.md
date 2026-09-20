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


## Production promotion contract

A `production-approved` registry entry fails closed unless the project has a consistent source identity, verified redistribution permission, explicit modification/attribution flags, a project-controlled artifact, a non-empty licence snapshot and provenance file, and hashes that still match all three preserved files.

The gate records and verifies:

- artifact SHA-256 and exact byte size;
- licence snapshot SHA-256;
- provenance-file SHA-256;
- source/version/licence/mirror fields cross-checked between registry and provenance;
- a timezone-aware retrieval timestamp;
- mandatory release rules from `policy/license_policy.json`.

`schemas/source_registry_v1.schema.json` documents the registry shape. `tools/vault_gate.py` remains the executable conditional authority for production promotion.
