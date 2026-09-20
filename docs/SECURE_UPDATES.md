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

The verifier uses Ed25519 against project-controlled public keys in `policy/trusted_pack_keys.json`. The signed payload is domain-separated and covers the complete manifest with only the top-level `signature` field removed. The restricted representation rejects duplicate JSON fields, non-ASCII object keys, floating-point values and unsafe-range integers. Every approved manifest must carry a signed positive `release_sequence`.

Release key IDs are SHA-256 fingerprints of the canonical public-key descriptor. Threshold policy is supported, and verification fails closed on unknown, unauthorized, duplicate or malformed signatures, public-key/key-ID mismatch, invalid cryptography, insufficient signatures, or an inactive trust root.

The repository trust root is deliberately `bootstrap-required`: no real release public key has been enrolled and no private signing key is stored in GitHub. Existing candidate packs therefore remain candidates until durable offline key custody and independent backup are established.

## Still blocked before automatic network updates

Cryptographic authenticity is not the whole update system. The signed `release_sequence` now provides a rollback-ordering primitive, but automatic remote pack updates remain disabled until clients persist the highest accepted sequence, enforce freshness, test atomic activation/recovery, and use a reviewed key-rotation/revocation protocol. Bundled application releases may update public trust material through normal code review and verify the bundled pack at release-build time, but remote self-rotation is not claimed yet.
