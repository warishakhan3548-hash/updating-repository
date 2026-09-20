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
- object keys restricted to ASCII and sorted deterministically;
- array order preserved;
- integers only within the cross-runtime safe integer range;
- floats forbidden;
- JSON string values encoded as supplied Unicode scalar values; invalid surrogate code points are rejected.

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
- status: `active`, `retired`, or `revoked`;
- positive `min_release_sequence`;
- `max_release_sequence`: null for an active key, a required finite ceiling for a retired key.

Meaning:

- `active`: may verify releases at or above its minimum sequence;
- `retired`: may verify only its explicitly bounded historical sequence window;
- `revoked`: never counts toward the trust threshold.

Sequence windows matter because merely labelling a key “retired” is not enough: if its old private key were later exposed, an unbounded verifier could incorrectly accept a newly signed future release. The verifier therefore checks the manifest's signed `release_sequence` against every candidate key's trusted window before that signature can count.

The policy also has `signature_threshold`. Multiple signatures from the same key count once. This supports rotation and future multi-key approval without changing the payload format.

## Rotation

Normal rotation:

1. generate the new private key outside the repository;
2. review and commit only its public key as `active`;
3. publish at least one release signed by the new key;
4. move the previous key to `retired` and set `max_release_sequence` to the last release it is authorized to verify;
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


## Android boundary

The current reader supports API 24+, while Android's platform `java.security.Signature` documentation lists built-in Ed25519 support from API 33. Repository/build-time verification therefore does not imply that the current Android runtime can independently verify Ed25519 on every supported device. Release activation stays fail-closed until a deliberately chosen, tested min-API-compatible verification strategy exists.
