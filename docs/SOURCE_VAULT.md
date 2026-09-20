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
