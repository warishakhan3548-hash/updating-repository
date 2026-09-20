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

For the Tanzil Quran pack, notice text is derived from comment lines in the exact preserved production artifact. The importer does not author substitute licence wording.

## Promotion

- `candidate`: deterministic build output; not release-approved.
- `reviewed`: technically/content reviewed.
- `approved`: cryptographically verified against the project trusted-key threshold.

For `approved`, `tools/pack_gate.py` delegates to `tools/pack_signing.py`. The manifest must carry a positive signed `release_sequence` plus an Ed25519 signature block using payload format `aaris-pack-json-v1`; enough non-revoked keys from `policy/trusted_pack_keys.json` must verify to meet `signature_threshold`.

The production trusted-key policy is intentionally empty today, so no current pack is approvable yet. Presence of signature-shaped strings alone never passes the gate. See `PACK_SIGNING.md` for canonical payload, rotation and rollback-metadata rules.

Content versions are immutable. Stronger trust contracts use a new content version rather than rewriting an older pack. Previous verified release packs remain available for rollback and reproducibility.
