# Secure Content Updates

Content packs are versioned independently from the app.

Before activation:

1. verify manifest/source-vault binding;
2. verify expected pack ID and dependency versions;
3. verify the pack signature against project-controlled trusted public keys;
4. verify artifact SHA-256 and size;
5. run source-specific semantic integrity probes;
6. reject rollback below the locally trusted version unless an explicit recovery path is invoked;
7. open the pack read-only;
8. atomically switch the active-pack pointer and retain the previous verified pack.

The design borrows TUF threat-model principles—separate trusted keys, threshold signatures, integrity and rollback resistance—without importing a full network-update framework before the product actually has remote content distribution.

## Implemented authenticity boundary

`tools/pack_signatures.py` now verifies `approved` manifests with Ed25519 signatures against `policy/trusted_pack_keys.json`.

The signed payload is the complete manifest with the top-level `signature` field removed and serialized as deterministic UTF-8 JSON with sorted keys and compact separators. Floating-point values are forbidden in signed metadata so that cross-language number rendering cannot silently change the payload.

Release key IDs are content-derived SHA-256 fingerprints of the canonical Ed25519 public-key descriptor. The verifier supports role thresholds and fails closed on:

- unknown or unauthorized keys;
- duplicate key IDs;
- malformed signature entries;
- unsupported algorithms;
- public-key/key-ID mismatch;
- invalid signatures;
- insufficient valid signatures;
- an inactive or malformed trust root.

Private signing keys are never stored in this repository.

## Bootstrap state

The checked-in trust-root file is deliberately `bootstrap-required`: no real release public key has been enrolled yet. Therefore the existing `quran-core@1.0.4` remains a candidate and cannot honestly be promoted to `approved`.

A real release key must be generated and backed up outside GitHub, then only its public key and derived key ID may be committed. Key custody should be independently recoverable before the first production approval.

## Still pending before network content updates

Signature authenticity is only one layer. Automatic remote content updates remain disabled until the project also has:

- a persistent local monotonic/rollback state;
- signed freshness/version metadata appropriate to the update channel;
- a documented key-rotation/revocation ceremony;
- atomic activation and recovery tests on Android;
- an independent backup/archive of the critical trust-root history.

Repository review can rotate trusted public keys for bundled app releases today, but remote self-rotation is intentionally not claimed.
