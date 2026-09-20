# Content Pack Manifest Spec

A runtime content pack is a derived artifact, never the surviving source of truth. Every pack must trace to one **production-approved** Source Vault entry.

## Schema v1

Schema v1 remains supported for historical packs. For attribution-required sources it requires a pack-local `notice_path` plus `notice_sha256`, validates the hash, and keeps both the runtime artifact and notice inside the immutable pack-version directory even after symlink resolution.

Schema v1 does not bind notice wording, licence snapshot identity, or provenance identity back to the Source Vault. Existing v1 packs are not rewritten in place.

## Schema v2 — provenance-bound pack

Schema v2 retains all v1 checks and additionally requires:

- `source_url`;
- `source_attribution`;
- `source_licence_url`;
- `source_licence_sha256`;
- `source_provenance_sha256`;
- `notice_path` and `notice_sha256`.

`tools/pack_gate.py` loads the pinned Source Vault provenance and requires those values to match it. For SQLite packs, the same source identity, attribution, licence/provenance hashes, notice hash, and exact notice text must also exist inside `pack_metadata`.

For `quran-core`, schema v2 additionally performs importer-independent semantic verification against the preserved Source Vault and canonical SQLite schema. Promotion verifies the source assertion, required runtime metadata, all 6,236 Quran `original_text` rows, recomputed search lanes, and absence of undeclared morphology/Hadith evidence. Recomputing only an outer file hash therefore cannot legitimize altered sacred text or schema drift.

For the Tanzil Quran pack, notice text is derived from comment lines in the exact preserved production artifact. The importer does not author substitute licence wording.

## Promotion states

- `candidate`: deterministic build output; not release-approved.
- `reviewed`: technically/content reviewed.
- `approved`: all ordinary gates pass and the manifest's release signature verifies against the active project trust root.

An approved signature block uses:

```json
{
  "format": "aaris-pack-signature-v1",
  "role": "content-pack-release",
  "signatures": [
    {
      "algorithm": "ed25519",
      "key_id": "<64-lowercase-hex-key-id>",
      "value": "<128-lowercase-hex-signature>"
    }
  ]
}
```

The signed bytes are deterministic JSON for the entire manifest **except** the top-level `signature` field. This means source identity, hashes, record counts, dependencies, content version, review status and all other manifest assertions are covered by the signature.

`tools/pack_gate.py` delegates approved-manifest verification to `tools/pack_signatures.py`; mere presence of signature-looking strings is never sufficient.

## Trust root

Trusted release public keys and threshold policy live in `policy/trusted_pack_keys.json`. Key IDs are derived from the public key, not human-selected labels. Private keys must remain outside the repository.

The current policy state is `bootstrap-required`, so no existing candidate pack is promoted merely because the verifier now exists.

Content versions are immutable. Stronger trust contracts or changed source bytes use a new content version rather than rewriting an older pack. Previous verified release packs remain available for reproducibility and later rollback support.
