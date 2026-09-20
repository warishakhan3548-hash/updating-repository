# Content Pack Signing

Content-pack signatures authenticate a reviewed runtime artifact after Source Vault, licence, provenance, checksum and schema validation have already passed. They do not replace those gates.

## Algorithm

Release signatures use Ed25519.

Verification is implemented through the replaceable Python `cryptography` adapter pinned in `requirements-foundation.txt`. The Evidence Plane does not depend on this library's data model.

Private release keys MUST NOT be committed to this repository, CI logs, content packs or the Source Vault.

## Signed payload

Payload format: `aaris-pack-json-v1`.

The verifier signs the complete manifest except the top-level `signature` field, prefixed with the domain separator:

`AARIS-CONTENT-PACK-SIGNATURE-V1\n`

Canonicalization is deliberately narrow:

- UTF-8;
- no Unicode normalization;
- object keys sorted deterministically;
- array order preserved;
- integers only within the cross-runtime safe integer range;
- floats forbidden;
- JSON strings encoded deterministically.

This is a project-owned restricted format, not a claim of full RFC 8785/JCS conformance. The restriction keeps the payload simple enough to implement identically on Android later.

## Manifest signature block

An approved manifest uses this shape conceptually:

```json
{
  "release_sequence": 1,
  "review_status": "approved",
  "signature": {
    "status": "signed",
    "payload_format": "aaris-pack-json-v1",
    "signatures": [
      {
        "algorithm": "ed25519",
        "key_id": "release-key-id",
        "value": "<base64 Ed25519 signature>"
      }
    ]
  }
}
```

`release_sequence` is inside the signed payload. It is the rollback-ordering primitive for future device activation. A device must persist the highest accepted sequence and reject lower sequences except through an explicit recovery procedure.

The repository build gate validates that the sequence is a positive integer. Persistent device-side anti-rollback state is not implemented yet.

## Trusted public keys

`policy/trusted_pack_keys.json` is the project trust root for pack-release public keys.

Each key has:

- a stable `key_id`;
- `algorithm = ed25519`;
- raw 32-byte public key encoded as base64;
- status: `active`, `retired`, or `revoked`.

Meaning:

- `active`: may verify current and historical releases;
- `retired`: no longer used to sign new releases, but may verify historical releases;
- `revoked`: never counts toward the trust threshold.

The policy also has `signature_threshold`. Multiple signatures from the same key count once. This supports rotation and future multi-key approval without changing the payload format.

## Rotation

Normal rotation:

1. generate the new private key outside the repository;
2. review and commit only its public key as `active`;
3. publish at least one release signed by the new key;
4. move the previous key to `retired`;
5. keep retired public keys while historical releases must remain verifiable.

Compromise response:

1. mark the compromised public key `revoked`;
2. enroll a new reviewed public key;
3. issue a higher `release_sequence`;
4. require clients to reject the compromised key and older sequence.

Changing trusted keys is a security-sensitive code review event.

## Current state

No production release public key is enrolled yet. Therefore no manifest can currently satisfy the threshold for `approved`.

The existing `quran-core 1.0.4` remains an immutable unsigned candidate. It is not rewritten in place merely to add a signature. Promotion requires a new immutable content version after an offline release-key ceremony and content review.

Tests use the public RFC 8032 Ed25519 test key only. That test private seed is public test material and MUST NEVER become a production release key.
