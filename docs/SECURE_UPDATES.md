# Secure Content Updates

Content packs are versioned independently from the app.

Before activation:

1. verify manifest schema;
2. verify expected pack ID and dependency versions;
3. verify cryptographic signature;
4. verify file SHA-256 and size;
5. reject rollback below the highest trusted release sequence already accepted by this installation;
6. open the pack read-only and run integrity probes;
7. atomically switch the active content;
8. retain a recovery path for the prior verified state.

The design follows TUF principles—trusted metadata, freshness, integrity and rollback resistance—without importing unnecessary machinery before real update distribution exists.

## Current implementation status

Hash, provenance, canonical-v3 binding and Quran semantic validation are implemented. Trusted-key authenticity is implemented for `approved` manifests in `tools/pack_signatures.py`.

The verifier uses Ed25519 against project-controlled public keys in `policy/trusted_pack_keys.json`. The signed payload is application-domain-separated and covers the complete manifest with only the top-level `signature` field removed, serialized as restricted deterministic UTF-8 JSON. Duplicate object names, floating-point values, cross-runtime-unsafe integers and ambiguous signed metadata are rejected.

Release key IDs are SHA-256 fingerprints of the canonical public-key descriptor. Threshold policy is supported, and verification fails closed on unknown, unauthorized, duplicate or malformed signatures, public-key/key-ID mismatch, invalid cryptography, insufficient signatures, or an inactive trust root.

Approved manifests require a positive signed `release_sequence`. The Android release reader now additionally persists the highest accepted sequence together with the exact pack SHA-256. A lower sequence is rejected even when its signature/hash would otherwise be valid, and the same sequence cannot be rebound to different bytes.

That acceptance state is stored under `noBackupFilesDir/content/activation/` and written with Android `AtomicFile`. This keeps the small security state outside automatic backup/restore and makes a crash during state replacement fall back to the prior complete file. Release pack installation also uses `AtomicFile` after hashing a temporary copy, avoiding delete-then-rename activation.

Debug candidate builds deliberately do not advance production rollback state. The current quran-core 1.1.0 candidate has no production `release_sequence`, so ordinary development remains possible while release builds continue to fail closed.

The repository trust root is deliberately `bootstrap-required`: no real release public key has been enrolled and no private signing key is stored in GitHub. Existing candidate packs therefore remain candidates until durable offline key custody and independent backup are established.

## Security boundary and limitations

The persisted highest-sequence state protects an installed app from accepting an older signed bundled release after it has seen a newer one. It survives ordinary app upgrades because it lives in internal app storage, but clearing app data or uninstalling the app removes it; this is not claimed to be hardware-backed monotonic storage.

Automatic remote pack updates remain disabled. Before enabling them, the project still needs:

- a reviewed on-device signature-verification path that works across the supported Android API range;
- freshness/expiry metadata so a client can detect freeze attacks rather than only rollback;
- downloaded-pack staging, atomic active-pointer switching and explicit recovery tests;
- reviewed trust-root rotation/revocation behavior;
- network/update threat-model and failure-injection testing.

Bundled application releases may continue to update public trust material through normal code review, while remote self-rotation remains out of scope.
