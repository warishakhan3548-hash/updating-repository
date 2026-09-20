# Content Signing and Key Custody

## Purpose

Content-pack signing proves that an `approved` manifest was authorized by project-controlled release keys after source, licence, semantic and integrity review. It does **not** replace those earlier gates.

## Trust model

The repository stores only public trust material in `policy/trusted_pack_keys.json`.

The release role is `content-pack-release`. Its policy contains an explicit signature threshold and the allowed key IDs. The verifier accepts only Ed25519 for signature format v1.

A key ID is the SHA-256 of deterministic JSON containing the algorithm and exact 32-byte lowercase-hex public key. This prevents a human-friendly label from silently being rebound to different key bytes.

## Signed payload

The signed payload is the complete manifest with the top-level `signature` property removed, prefixed with:

`AARIS-CONTENT-PACK-SIGNATURE-V1\n`

The remaining JSON is serialized as UTF-8 with sorted object keys and compact separators. Floats, integers outside the cross-runtime safe range, non-string object keys, and invalid Unicode surrogate values are rejected.

The manifest's positive `release_sequence` is therefore signed. Changing the sequence invalidates the signature.

The promotion gate also rejects duplicate JSON object keys before any trust decision. This prevents different parsers from interpreting the same manifest or source registry differently.

## Release sequence

`release_sequence` is a monotonic security ordering primitive, separate from human-facing `content_version`.

It is required only for `approved` packs. It will be used by future device activation logic to reject rollback below the highest trusted sequence already accepted by that installation.

A signed sequence by itself is **not** complete anti-rollback protection. The Android updater must later persist the highest accepted sequence in user/device state and fail closed on lower values except through an explicit recovery procedure.

## Trusted-key lifecycle

Every enrolled public key records:

- `status`: `active`, `retired`, or `revoked`;
- `min_release_sequence`;
- `max_release_sequence`.

Active keys have no maximum. Retired keys must have a finite maximum so an old private key cannot authorize future releases after rotation. Revoked keys never verify a release.

Threshold verification remains role-based. Duplicate signatures from one key never satisfy multiple threshold slots.

## Bootstrap ceremony

The repository intentionally starts with `state: bootstrap-required`.

Before the first production approval:

1. generate the Ed25519 private key on a trusted offline machine;
2. create at least one independent encrypted backup before relying on that key;
3. record who controls recovery and how loss/compromise is handled;
4. derive the raw public key and project key ID;
5. assign its lifecycle status and release-sequence window;
6. commit **only** the public key, key ID, release-role membership and threshold;
7. review that trust-root change separately from the pack being approved;
8. assign the next monotonic `release_sequence`;
9. sign the already-reviewed immutable manifest outside GitHub;
10. place only the resulting signature in the new immutable pack manifest;
11. run the full Source Vault, pack, semantic and Android release gates.

Never commit a seed, PEM private key, passphrase, recovery phrase or secret key material.

## Rotation and revocation

For normal rotation, enroll the replacement public key before relying on it. After the overlap release is accepted, mark the old key `retired` and cap its `max_release_sequence` at the last release it may authenticate.

A suspected-compromised key becomes `revoked`; it must not count toward the threshold at any sequence.

Remote self-updating trust metadata remains out of scope until persistent anti-rollback/freshness state and a stronger update protocol are implemented.

## Dependency boundary

`cryptography` is pinned only for CI/release verification. Android runtime does not depend on Python or this package. The signature format, canonical payload, release ordering and trust-root schema are project-owned contracts so the implementation library remains replaceable.
