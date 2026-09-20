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

The verifier uses Ed25519 against project-controlled public keys in `policy/trusted_pack_keys.json`. The signed payload is the complete manifest with only the top-level `signature` field removed, serialized as deterministic UTF-8 JSON with sorted keys and compact separators. Floating-point values are rejected in signed metadata to avoid cross-language numeric canonicalization ambiguity.

Release key IDs are SHA-256 fingerprints of the canonical public-key descriptor. Threshold policy is supported. Enrolled keys are explicitly active, retired, or revoked and are bound to release-sequence validity windows; retired keys can remain available for historical verification without authorizing newer sequences, and revoked keys never count. An active policy must have enough active authorized keys to satisfy its threshold.

Approved manifests now also require a positive integer `release_sequence`. The value is inside the signed payload, so changing release order after signing invalidates approval. This provides the deterministic ordering primitive needed for later rollback resistance without pretending that client-side rollback protection already exists.

The repository trust root is deliberately `bootstrap-required`: no real release public key has been enrolled and no private signing key is stored in GitHub. The project now has a fail-closed offline signer that consumes only encrypted out-of-repository Ed25519 private keys and can add authorized signatures to manifests that were already approved, but tooling readiness is not key custody. Existing candidate packs therefore remain candidates until durable offline key generation, independent backup and separate public trust-root review are completed.

## Still blocked before automatic network updates

Cryptographic authenticity, signed ordering and installed-app rollback state are not the whole update system. Automatic remote pack updates remain disabled until the project handles freshness/expiry, downloaded-pack staging, explicit activation/recovery tests, supported-API on-device signature verification, and remote key-rotation/revocation protocol. Bundled application releases may update public trust material through normal code review, but remote self-rotation is not claimed yet.

## Installed-app rollback state

The signed `release_sequence` is now enforced by Android runtime state for non-debug bundled releases. After the authoritative build-time pack gate approves a release, the reader requires a positive release sequence and persists the highest accepted sequence together with the exact pack SHA-256 under `noBackupFilesDir/content/activation/`.

A candidate below the stored sequence is rejected even if its older signature and hash are otherwise valid. Reusing the same sequence for different bytes is also rejected. Debug candidate builds do not advance this production state.

The rollback-state record is written with Android `AtomicFile`. Bundled `content.sqlite` replacement is likewise performed only after a temporary copy passes SHA-256 verification, then written through `AtomicFile` and re-hashed after activation. This removes the previous delete-then-rename crash window.

This is an installed-app rollback barrier, not hardware-backed monotonic storage. Uninstall or clear-data removes app-internal state. Automatic remote pack updates remain disabled until freshness/expiry, downloaded-pack staging, explicit recovery, supported-API on-device signature verification, and remote trust-rotation behavior are reviewed and tested.
