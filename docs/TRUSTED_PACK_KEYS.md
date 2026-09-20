# Trusted Content-Pack Keys

This document defines the release-authenticity boundary for runtime content packs. It is intentionally narrower than a full TUF implementation, but it adopts the relevant TUF principles: trusted roots are versioned, signatures are verified cryptographically, thresholds count distinct trusted keys, key IDs are derived from canonical public-key metadata, and rollback metadata is part of the signed payload.

## Current state

No production release private key has been provisioned.

`policy/trusted-pack-keys/root-v1.json` is an immutable bootstrap record with zero active keys. Its threshold therefore cannot be satisfied. This is deliberate: no pack can become `approved` merely by adding signature-shaped strings.

The current `quran-core@1.0.4` remains `candidate` and unsigned.

## Trust-root versions

Trust roots live at:

`policy/trusted-pack-keys/root-vN.json`

A root version is immutable after publication. Key addition, revocation, or threshold changes create a new root version instead of rewriting historical trust.

An approved manifest pins its root with:

`signature.trust_root_version`

The verifier requires the manifest version and selected root file to agree.

## Keys

The supported initial signature scheme is Ed25519.

A trusted key object is:

```json
{
  "keytype": "ed25519",
  "scheme": "ed25519",
  "status": "active",
  "keyval": {
    "public": "<32-byte lowercase hex public key>"
  }
}
```

Private keys MUST NOT be committed to this repository, stored in the Source Vault, embedded in the Android app, or placed in ordinary CI variables. Production signing keys should be generated and held offline or in an explicitly approved signing system.

A key ID is the SHA-256 of this canonical key object:

`{"keytype":"ed25519","keyval":{"public":"..."},"scheme":"ed25519"}`

using UTF-8 JSON with sorted keys, no insignificant whitespace and no floating-point numbers.

## Signed manifest payload

Payload version:

`aaris-pack-manifest-v1`

The signature covers the entire manifest except the top-level `signature` object. The payload uses UTF-8 JSON with sorted keys and compact separators. Floating-point values are rejected to avoid cross-implementation canonicalization ambiguity.

Because `review_status`, `built_sha256`, provenance fields, dependencies, `content_version`, and `release_sequence` are inside the signed payload, altering any of them invalidates the signature.

## Approved-pack signature object

An approved pack uses:

```json
{
  "signature": {
    "payload_version": "aaris-pack-manifest-v1",
    "trust_root_version": 2,
    "signatures": [
      {
        "algorithm": "ed25519",
        "key_id": "<trusted key id>",
        "value": "<64-byte lowercase hex signature>"
      }
    ]
  }
}
```

Only distinct, active, trusted key IDs count toward the root threshold. Duplicate key IDs are rejected. Unknown or revoked keys do not count.

## Rollback metadata

Every approved pack requires a positive integer `release_sequence`, and that value is signed.

Repository verification ensures that the sequence cannot be altered without invalidating the signature. This is only half of rollback protection: a client that downloads future updates must also persist the highest trusted sequence it has accepted and reject lower sequences.

Therefore remote content-pack updates MUST remain disabled until the Android/client activation layer implements durable anti-rollback state plus signature verification against the shipped trusted root. Bundling a reviewed pack inside an APK remains a separate build-time trust path protected by repository gates and APK signing.

## Rotation

1. Keep the old root immutable.
2. Create `root-v(N+1).json`.
3. Add or revoke public keys and set the new threshold.
4. Review the new root out-of-band.
5. Sign new packs against the new root version.
6. Keep historical roots so old release artifacts remain reproducibly verifiable.

A later migration may adopt full TUF root-update rules. Do not silently mutate an old root file to simulate rotation.

## Dependency

Repository Ed25519 verification uses the pinned PyCA `cryptography` dependency in `requirements-trust.txt`. Candidate/reviewed pack validation loads no cryptography code; the dependency is required only for approval verification and its tests.
