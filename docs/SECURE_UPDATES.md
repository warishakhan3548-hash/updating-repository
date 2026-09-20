# Secure Content Updates

Content packs are versioned independently from the app.

Before activation:

1. verify manifest schema;
2. verify expected pack ID and dependency versions;
3. verify cryptographic signature;
4. verify file SHA-256 and size;
5. reject rollback below the trusted version unless an explicit recovery path is invoked;
6. open the pack read-only and run integrity probes;
7. atomically switch the active-pack pointer;
8. retain the prior verified pack for rollback.

The design follows TUF principles—trusted metadata, freshness, integrity and rollback resistance—without importing unnecessary machinery before real update distribution exists.

## Current implementation status

Hash, provenance, canonical-v3 binding and Quran semantic validation are already implemented. Trusted-key authenticity is now implemented for `approved` manifests in `tools/pack_signatures.py`.

The verifier uses Ed25519 against project-controlled public keys in `policy/trusted_pack_keys.json`. The signed payload is the complete manifest with only the top-level `signature` field removed, prefixed by a project-specific domain separator and serialized as restricted deterministic UTF-8 JSON. Floats, unsafe-width integers, invalid Unicode scalar values, and duplicate JSON object keys are rejected to avoid cross-parser/cross-runtime ambiguity.

Release key IDs are SHA-256 fingerprints of the canonical public-key descriptor. Approved packs also carry a signed positive `release_sequence`. Threshold policy is supported, keys have active/retired/revoked lifecycle state plus release-sequence windows, and verification fails closed on unknown, unauthorized, duplicate, revoked, out-of-window or malformed signatures, public-key/key-ID mismatch, invalid cryptography, insufficient signatures, or an inactive trust root.

The repository trust root is deliberately `bootstrap-required`: no real release public key has been enrolled and no private signing key is stored in GitHub. Existing candidate packs therefore remain candidates until durable offline key custody and independent backup are established.

## Still blocked before automatic network updates

Cryptographic authenticity and signed ordering are not the whole update system. Automatic remote pack updates remain disabled until Android persists the highest accepted release sequence, freshness metadata exists, atomic activation/recovery is tested, and the reviewed key-rotation/revocation procedure is exercised. Bundled application releases may update public trust material through normal code review, but remote self-rotation is not claimed yet.
