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

Approved manifests require a positive integer `release_sequence`. The value is inside the signed payload, so changing release order after signing invalidates approval.

The Android release reader persists the highest accepted sequence in `noBackupFilesDir/trust/quran-core.release-sequence` using the platform `AtomicFile` primitive. A lower release sequence is rejected before bundled-pack activation. The state advances only after the exact bundled pack has passed the runtime SHA-256 check and activation succeeds. Debug candidate builds do not create or consume this production trust state.

This closes the bundled-release rollback gap without pretending that it is a complete network update system. The state is deliberately excluded from Android automatic backup so restoring an older cloud backup cannot silently lower the device's remembered content release. Uninstalling the app or clearing app data still removes local trust state; this mechanism is not a hardware-backed anti-tamper claim.

The repository trust root is deliberately `bootstrap-required`: no real release public key has been enrolled and no private signing key is stored in GitHub. Existing candidate packs therefore remain candidates until durable offline key custody and independent backup are established.

## Still blocked before automatic network updates

Automatic remote pack updates remain disabled. Before downloaded-pack activation exists, the project still needs a reviewed on-device signature-verification path compatible with minSdk 24, freshness/expiry metadata, atomic downloaded-pack activation and recovery, and explicit trust-recovery semantics. Bundled application releases may update public trust material through normal code review; remote self-rotation is not claimed yet.
