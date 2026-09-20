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

Hash, provenance, canonical-v3 binding and Quran semantic validation are already implemented. Trusted-key authenticity is implemented for `approved` manifests in `tools/pack_signatures.py`. Before any production key is enrolled, the signing contract is finalized as domain-separated `aaris-pack-signature-v2`.

The verifier uses Ed25519 against project-controlled public keys in `policy/trusted_pack_keys.json`. The signed payload is the complete manifest with only the top-level `signature` field removed, serialized as deterministic UTF-8 JSON with sorted keys and compact separators. Floating-point values are rejected in signed metadata to avoid cross-language numeric canonicalization ambiguity.

Release key IDs are SHA-256 fingerprints of the canonical public-key descriptor. Threshold policy is supported, and trusted keys have active/retired/revoked state plus `release_sequence` authorization windows. Verification fails closed on unknown, unauthorized, out-of-window, revoked, duplicate or malformed signatures, public-key/key-ID mismatch, invalid cryptography, insufficient signatures, or an inactive trust root.

Approved manifests now also require a positive integer `release_sequence`. The value is inside the signed payload, so changing release order after signing invalidates approval. This provides the deterministic ordering primitive needed for later rollback resistance without pretending that client-side rollback protection already exists.

The repository trust root is deliberately `bootstrap-required`: no real release public key has been enrolled and no private signing key is stored in GitHub. Existing candidate packs therefore remain candidates until durable offline key custody and independent backup are established.

## Still blocked before automatic network updates

Cryptographic authenticity and a signed ordering primitive are not the whole update system. Automatic remote pack updates remain disabled until the project persists the highest accepted `release_sequence`, handles freshness/expiry, tests atomic activation/recovery, and reviews key-rotation/revocation protocol. Bundled application releases may update public trust material through normal code review, but remote self-rotation is not claimed yet.
