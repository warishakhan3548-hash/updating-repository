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
- `approved`: reserved for a pack whose cryptographic signature has actually been verified against a trusted project key.

Approved packs are verified cryptographically by `tools/pack_signing.py` before promotion. The signed payload is the complete manifest except its top-level `signature` field, so schema-v3 canonical bindings, Source Vault provenance, hashes, toolchain metadata, dependencies, review status and signed `release_sequence` are authenticated together.

The trusted-key policy supports threshold verification, SHA-256 public-key fingerprint IDs, active/retired/revoked states, pack scoping, and release-sequence windows. See `docs/PACK_SIGNING.md`.

**Current fail-closed rule:** no production public key is enrolled yet. The policy threshold therefore cannot be met, so no pack can become `approved` until an explicit offline key ceremony and content review occur. Private release keys must never be created or stored merely to make CI green.

Content versions are immutable. Stronger trust contracts use a new content version rather than rewriting an older pack. Previous verified release packs remain available for rollback and reproducibility.
