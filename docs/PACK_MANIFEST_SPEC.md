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

This closes an important trust gap: a caller cannot replace a required notice or attribution with arbitrary text, recompute local hashes, and still pass the gate if those values no longer match the preserved Source Vault record.

For `quran-core`, schema v2 also performs importer-independent semantic verification against the preserved Source Vault and canonical SQLite schema. Promotion verifies the source assertion, required runtime metadata, all 6,236 Quran `original_text` rows, recomputed search lanes, and that undeclared morphology/Hadith evidence is absent. A fresh outer file hash therefore cannot legitimize altered sacred text or schema drift.

For the Tanzil Quran pack, notice text is derived from comment lines in the exact preserved production artifact. The importer does not author substitute licence wording.

## Schema v3 — canonical-bound reproducible pack

Schema v3 retains the provenance and semantic checks of v2 and additionally requires:

- `content_schema_version`;
- a `canonical` binding containing canonical ID/version/generator, manifest path/hash, artifact path/hash/size, and record count;
- `build_toolchain` metadata for Python implementation/version and SQLite version;
- an explicit `byte_reproducibility_scope`.

The canonical Quran artifact is deterministic JSONL generated only from the preserved Source Vault source. Its loader validates coordinates, source identity, exact artifact bytes, and **row-for-row Quran text equality with the Source Vault artifact**. The runtime pack embeds the canonical identity/hash and is then independently semantically verified against Source Vault again.

This separates three properties that must not be confused: source provenance, canonical semantic fidelity, and runtime byte identity. A changed canonical/runtime file plus newly calculated hashes still fails when its Quran semantics no longer match preserved evidence.

Historical schema-v1/v2 packs remain immutable and verifiable under their own contracts; schema v3 does not rewrite them.

## Promotion

- `candidate`: deterministic build output; not release-approved.
- `reviewed`: technically/content reviewed.
- `approved`: all ordinary gates pass, `release_sequence` is a positive integer, and the manifest release signature verifies against the active project trust root.

Approved manifests use `aaris-pack-signature-v1`:

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

The signed bytes are the fixed application-domain prefix `AARIS-CONTENT-PACK-SIGNATURE-V1\\n` followed by deterministic JSON for the entire manifest except the top-level `signature` field. The prefix is part of the signed message and prevents these Ed25519 signatures from being interpreted as raw signatures for a different protocol. Source/canonical identities, hashes, record counts, dependency assertions, build metadata, content version, review status and `release_sequence` are therefore covered by the signature. The sequence is the monotonic ordering primitive for future anti-rollback state; current clients do not yet persist the highest accepted value for downloaded updates.

`tools/pack_gate.py` delegates approved-manifest authenticity to `tools/pack_signatures.py`; signature-shaped strings are never sufficient. Trusted release public keys and threshold policy live in `policy/trusted_pack_keys.json`. Key IDs are derived from the public key, and private keys must remain outside the repository.

The current trust-root state is `bootstrap-required`, so verifier availability does **not** promote existing candidates. A real offline release key and independent backup must be established first.

Content versions are immutable. Stronger trust contracts use a new content version rather than rewriting an older pack. Previous verified release packs remain available for reproducibility and later rollback support.
