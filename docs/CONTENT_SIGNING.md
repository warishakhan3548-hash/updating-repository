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

Every approved manifest must carry a positive integer `release_sequence`. Because it is outside the excluded signature block, the sequence is authenticated by every release signature. It is an app-owned monotonic ordering primitive for rollback protection and does not depend on semantic-version string parsing.

Bundled Android releases persist the highest accepted sequence and exact pack hash under no-backup storage. Automatic downloaded-pack activation remains disabled.

## Release freshness

Approved manifests must also carry signed `release_issued_at` and `release_expires_at` timestamps in canonical UTC seconds. The v1 policy requires expiry after issue time and limits the window to 366 days. The offline signer validates this structure before adding a signature, so freshness metadata cannot be bolted on after signing without invalidating the release.

Historical verification deliberately does not fail merely because `release_expires_at` has passed. Expiry is checked when making a **new activation** trust decision. This keeps reproducible archives stable while preventing a future downloader from treating indefinitely replayed release metadata as fresh.

The 366-day cap is not a substitute for TUF-style short-lived Timestamp/Snapshot metadata. A future network update channel still needs a separately authenticated, frequently refreshed freshness layer.

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

## Offline signing tool

`tools/offline_release_signer.py` makes the release ceremony reproducible without turning GitHub or CI into a key custodian. It never generates a production key and never writes private-key bytes. It accepts only an encrypted PKCS#8 Ed25519 PEM whose resolved path is outside this repository, and it prompts for the password interactively so a passphrase does not need to appear in command-line arguments.

Generate the production key on the trusted offline machine, not in CI. With OpenSSL, one suitable interactive form is:

```bash
openssl genpkey -algorithm ED25519 -aes-256-cbc -out /offline/path/aaris-content-release.pem
```

Create and verify at least one independent encrypted backup before enrolling the key. Then inspect only the public identity:

```bash
python tools/offline_release_signer.py inspect-key /offline/path/aaris-content-release.pem
```

The command prints only the raw Ed25519 public key and the project-derived key ID. Use those public values in a separately reviewed trust-root change. Do not activate the trust policy until custody/recovery has actually been completed.

The signer deliberately cannot turn a candidate into an approved pack. It signs only a manifest whose `review_status` is already `approved`, whose positive `release_sequence` is valid, and whose derived key ID is an active authorized release key within its sequence window. Signing writes a **new** output file and refuses to overwrite the source or an existing output.

Example after review, trust-root activation, and creation of a new immutable approved pack version:

```bash
python tools/offline_release_signer.py sign \
  /path/to/approved-manifest.json \
  /offline/path/aaris-content-release.pem \
  policy/trusted_pack_keys.json \
  /path/to/signed-manifest.json
```

Threshold signatures are additive: another authorized offline key can sign the prior signed output into another new file. The top-level `signature` block is excluded from the authenticated payload, so every signer authorizes the same immutable manifest content rather than a previous signer's signature bytes. The final repository pack gate remains authoritative for threshold verification.

The current `quran-core 1.1.0` remains candidate/unsigned. Do not mutate that immutable candidate in place merely to exercise this tool; the first production approval must be represented as a new reviewed immutable pack version.

## Rotation and revocation

Every enrolled release public key carries explicit lifecycle metadata:

- `status`: `active`, `retired`, or `revoked`;
- `min_release_sequence`: the first release sequence the key may authenticate;
- `max_release_sequence`: null for an active key, finite for a retired key.

For bundled application releases, trust-root changes are code-reviewed repository changes. Add the replacement public key as `active` before depending on it. After an overlap release, keep the previous public key for historical verification but mark it `retired` and cap its maximum sequence at the last release it was authorized to sign. A later compromise of that retired private key therefore cannot authorize a future release sequence.

A lost or suspected-compromised private key becomes `revoked`; revoked signatures never count toward the release threshold. An active trust policy must retain enough active authorized keys to satisfy its configured threshold.

Remote self-updating trust metadata is deliberately out of scope until rollback/freshness state and a stronger update protocol are implemented.

## Dependency boundary

`cryptography` is pinned only for CI/release verification. Android runtime does not depend on Python or this package. The signature format, canonical payload and trust-root schema are project-owned contracts so the implementation library remains replaceable.

The current bundled-release boundary verifies Ed25519 at build time. Android's platform Ed25519 `Signature` support begins at API 33 while this app supports older devices, so a future **on-device downloaded-pack verifier must not assume platform Ed25519 is available on every supported device**. Before remote updates ship, choose and test either a reviewed compatible Ed25519 implementation/provider or a versioned signature-format migration that has native support across the supported API range.
