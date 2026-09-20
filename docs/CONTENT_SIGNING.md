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

The signed payload begins with the fixed byte domain `AARIS-CONTENT-PACK-SIGNATURE-V1\\n`, followed by the complete manifest with the top-level `signature` property removed. The fixed prefix gives this project-owned Ed25519 use an application-level signature domain, reducing the risk that the same release key/signature bytes are accidentally interpreted by another protocol. Signature arrays are excluded so independent authorized keys can sign the same immutable payload.

Signature format v1 deliberately uses a narrow, project-owned JSON contract rather than claiming full RFC 8785/JCS conformance:

- duplicate object names are rejected before interpretation;
- object-property names must be 7-bit ASCII, so Python/Java/Kotlin/ECMAScript sorting agrees without UTF-16 edge cases;
- property names are recursively sorted and JSON is emitted as compact UTF-8;
- floating-point values, NaN and Infinity are forbidden;
- signed integers are limited to ±9,007,199,254,740,991, the exact cross-runtime safe range;
- Unicode string **values** are preserved exactly as supplied; they are not normalized or transliterated.

These restrictions keep Arabic attribution or other Unicode string values intact while preventing a future verifier from authenticating different bytes because of duplicate names, numeric precision or property-ordering differences. If the format ever needs richer numeric/property-name semantics, introduce a new signature-format version rather than silently changing v1.

## Release ordering

Every approved manifest must carry a positive integer `release_sequence`. Because it is outside the excluded signature block, the sequence is authenticated by every release signature. It is an app-owned monotonic ordering primitive for future rollback protection and does not depend on semantic-version string parsing.

The repository verifier checks that the value is a positive integer. Automatic downloaded-pack activation is still blocked until clients persist the highest accepted sequence and reject lower values except through an explicit recovery procedure.

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

Remote self-updating trust metadata is deliberately out of scope until rollback/freshness state and a stronger update protocol are implemented.

## Dependency boundary

`cryptography` is pinned only for CI/release verification. Android runtime does not depend on Python or this package. The signature format, canonical payload and trust-root schema are project-owned contracts so the implementation library remains replaceable.

The current bundled-release boundary verifies Ed25519 at build time. Android's platform Ed25519 `Signature` support begins at API 33 while this app supports older devices, so a future **on-device downloaded-pack verifier must not assume platform Ed25519 is available on every supported device**. Before remote updates ship, choose and test either a reviewed compatible Ed25519 implementation/provider or a versioned signature-format migration that has native support across the supported API range.
