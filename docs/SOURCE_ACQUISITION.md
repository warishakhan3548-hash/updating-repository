# Source Acquisition

Acquisition is intentionally separate from Source Vault promotion.

A network fetch can create a **staged candidate snapshot**. It cannot make that source production-approved. Promotion still requires licence review, provenance review, immutable project-controlled placement, hashes, registry update, and all Source Vault gates.

## QuranEnc Arabic difficult-word glosses

`tools/quranenc_snapshot.py` stages an exact API snapshot for the QuranEnc `arabic_seraj` translation key.

The tool is fail-closed:

- the expected upstream version must be supplied explicitly;
- translation metadata is fetched before and after acquisition;
- any version or `last_update` drift discards the entire partial snapshot;
- all 114 surahs must match the existing Quran-core 6,236-coordinate invariant;
- raw response bodies and the current QuranEnc terms page are stored byte-for-byte;
- every preserved response receives SHA-256 and byte-size metadata;
- an existing destination is never overwritten;
- no registry entry, content pack, or production status is changed.

Example staging command:

```bash
python tools/quranenc_snapshot.py \
  .source-staging/quranenc/arabic-seraj/1.0.0 \
  --expected-version 1.0.0
```

The staging directory is not itself the Source Vault. After acquisition, a reviewer must verify the exact source version, applicable republication terms, attribution/version obligations, response shape, coordinate semantics, and whether the snapshot may legally be archived and redistributed. Only then may the exact reviewed bytes be copied into an immutable `source-vault/.../<version>/` path with provenance and registry metadata.

A later upstream version is a new snapshot. Never replace bytes under an existing version path.

## Promotion checklist

Before changing a source to `production-approved`:

1. verify the official origin and exact version/edition;
2. archive the exact applicable licence/terms bytes;
3. confirm redistribution/modification/attribution obligations;
4. preserve exact artifact bytes under project control;
5. record SHA-256 and exact byte sizes;
6. create machine-readable provenance with a timezone-aware retrieval timestamp;
7. run `tools/vault_gate.py` and the full test suite;
8. build only from the preserved artifact, never from the upstream endpoint;
9. retain the prior version for reproducibility and rollback;
10. maintain an independent backup for critical source material where practical.
