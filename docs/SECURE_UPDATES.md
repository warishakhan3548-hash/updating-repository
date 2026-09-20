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

Approved manifests require a positive safe-integer `release_sequence`. The value is inside the signed payload, so changing release order after signing invalidates approval.

The Android bundled-release reader now persists the highest accepted sequence in `noBackupFilesDir/trust/quran-core.release-sequence` with `AtomicFile`. A lower production sequence is rejected before local replacement, and the state advances only after exact bundled bytes pass runtime SHA-256 verification and activation succeeds. Debug candidates do not create or mutate production rollback state.

The repository trust root is deliberately `bootstrap-required`: no real release public key has been enrolled and no private signing key is stored in GitHub. Existing candidate packs therefore remain candidates until durable offline key custody and independent backup are established.

## Still blocked before automatic network updates

Automatic remote pack updates remain disabled. Before downloaded-pack activation exists, the project still needs a reviewed on-device signature-verification path compatible with minSdk 24, freshness/expiry metadata, atomic downloaded-pack activation/recovery, and remote trust-root rotation semantics. Bundled application releases may update public trust material through normal code review, but remote self-rotation is not claimed yet.
