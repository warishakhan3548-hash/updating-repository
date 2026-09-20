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

## Promotion

- `candidate`: deterministic build output; not release-approved.
- `reviewed`: technically/content reviewed.
- `approved`: reserved for a pack whose cryptographic signature has actually been verified against a trusted project key.

An `approved` pack additionally requires a positive signed `release_sequence` and a `signature` object using payload contract `aaris-pack-manifest-v1`. `tools/pack_signatures.py` verifies Ed25519 signatures against an immutable versioned trust root under `policy/trusted-pack-keys/`; only distinct active trusted keys count toward the configured threshold. The entire manifest except the top-level `signature` object is canonicalized and signed, so changing content identity, hashes, provenance, dependencies, review status or release sequence invalidates the signature.

**Current fail-closed rule:** cryptographic verification is implemented, but no production release public key has been provisioned. `root-v1.json` is an intentionally unsatisfiable bootstrap trust root with zero active keys. The current Quran pack therefore remains `candidate`/unsigned until an offline-managed release key is provisioned in a new immutable root version and an explicit review/signing ceremony is completed. Private signing keys must never be committed to the repository.

A signed `release_sequence` makes rollback state tamper-evident, but future network-delivered updates still require the client to persist its highest accepted sequence and reject older signed packs. Remote pack updates remain out of scope until that client-side anti-rollback state exists. See `docs/TRUSTED_PACK_KEYS.md`.

Content versions and trust-root versions are immutable. Stronger trust contracts use new versions rather than rewriting historical artifacts. Previous verified release packs remain available for rollback and reproducibility.
