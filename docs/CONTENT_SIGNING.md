# Content Signing and Key Custody

## Purpose

Content-pack signing proves that an `approved` manifest was authorized by project-controlled release keys after source, licence, semantic and integrity review. It does **not** replace those earlier gates.

## Trust model

The repository stores only public trust material in `policy/trusted_pack_keys.json`.

The release role is `content-pack-release`. Its policy contains an explicit signature threshold and the allowed key IDs. The verifier accepts only Ed25519 for signature format v1.

A key ID is the SHA-256 of deterministic JSON containing:

```json
{"algorithm":"ed25519","public_key":"<32-byte-lowercase-hex-public-key>"}
```

This prevents a human-friendly label from silently being rebound to different key bytes.

## Signed payload

The signed payload is the complete manifest with the top-level `signature` property removed, prefixed by the domain separator `AARIS-CONTENT-PACK-SIGNATURE-V1\n`.

The project-owned canonicalization contract is intentionally narrower than general JSON:

- UTF-8 string values are preserved as supplied; no Unicode normalization is performed;
- JSON object keys must be ASCII, are sorted lexicographically, and duplicate object fields are rejected at the trust boundary;
- array order is preserved;
- floating-point values are forbidden;
- integers must stay within the cross-runtime safe integer range (±9,007,199,254,740,991).

Signature arrays are excluded so independent authorized keys can sign the same immutable payload.

Every `approved` manifest also requires a positive signed `release_sequence`. It is the monotonic rollback-ordering primitive for future downloadable updates. A future client must persist the highest accepted sequence and reject lower sequences except through an explicit recovery procedure.

## Bootstrap ceremony

The repository intentionally starts with `state: bootstrap-required`.

Before the first production approval:

1. generate the Ed25519 private key on a trusted offline machine;
2. create at least one independent encrypted backup before relying on that key;
3. record who controls recovery and how loss/compromise is handled;
4. derive the raw public key and project key ID;
5. commit **only** the public key, key ID, release-role membership and threshold;
6. review that trust-root change separately from the pack being approved;
7. sign the already-reviewed immutable manifest outside GitHub;
8. place only the resulting signature in the new immutable pack manifest;
9. run the full Source Vault, pack, semantic and Android release gates.

Never commit a seed, PEM private key, passphrase, recovery phrase or secret key material.

## Rotation and revocation

For bundled application releases, trust-root changes are code-reviewed repository changes. Add the replacement public key before depending on it; where practical use an overlap period/threshold so one compromised key alone cannot authorize a pack.

A lost or suspected-compromised private key must be removed from the release role before subsequent packs are approved.

Remote self-updating trust metadata is deliberately out of scope until persistent rollback/freshness state and a stronger update protocol are implemented. The current Android app bundles content inside the signed application and runs the authoritative project pack gate at release-build time; it does not claim remote self-update security.

## Dependency boundary

`cryptography` is pinned only for CI/release verification. Android runtime does not depend on Python or this package. The signature format, canonical payload and trust-root schema are project-owned contracts so the implementation library remains replaceable.
