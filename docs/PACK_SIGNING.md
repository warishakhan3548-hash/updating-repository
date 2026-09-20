# Content Pack Signing

Content-pack signatures authenticate release approval only after Source Vault, licence, provenance, artifact-integrity, canonical-binding and semantic-fidelity checks pass. A signature never replaces those gates.

## Signature format v2

Approved packs use Ed25519 with signature format `aaris-pack-signature-v2`.

The authenticated bytes are:

1. the ASCII domain separator `AARIS-CONTENT-PACK-SIGNATURE-V2\n`;
2. deterministic UTF-8 JSON for the complete manifest except the top-level `signature` field.

Canonicalization deliberately accepts only a narrow cross-runtime-safe value set:

- object keys are strings and sorted deterministically;
- array order is preserved;
- strings must contain valid Unicode scalar values;
- floats are forbidden;
- integers must be within ±9,007,199,254,740,991;
- duplicate JSON object keys are rejected before trust decisions.

The format is project-owned and intentionally narrower than general-purpose JSON canonicalization.

## Release ordering

Every `approved` manifest requires a positive signed `release_sequence`.

The sequence is a rollback-ordering primitive. Changing it after signing invalidates the signature.

The repository gate does **not** claim full device rollback protection. A future remote-update client must persist the highest accepted sequence and reject lower sequences except through an explicit recovery procedure.

## Trusted public-key policy

`policy/trusted_pack_keys.json` is the project-controlled release trust root.

Each enrolled Ed25519 public key has:

- a content-derived `key_id`;
- `status`: `active`, `retired`, or `revoked`;
- `min_release_sequence`;
- `max_release_sequence`.

Rules:

- active keys have no maximum sequence;
- retired keys require a finite historical maximum;
- revoked keys never authorize a release;
- signatures count only from keys named in the `content-pack-release` role;
- threshold policy may require more than one independent key.

Sequence windows prevent an old retired key from authorizing a future release if its private key is later exposed.

## Key custody and rotation

Private production keys MUST NOT be committed to Git, CI logs, content packs or the Source Vault.

Normal rotation:

1. generate/protect the new private key offline;
2. commit only its reviewed public key as active;
3. authorize it from the intended minimum release sequence;
4. publish a higher-sequence release;
5. retire the old key with a finite maximum sequence.

Compromise response marks the affected public key revoked and requires a higher-sequence release from remaining/new trusted keys.

## Current trust state

The repository trust root remains `bootstrap-required` and contains no production public key. Therefore no current Quran pack is release-approved.

`quran-core 1.1.0` is an immutable unsigned schema-v3 candidate. It must not be rewritten merely to add approval metadata; a future signed release uses a new immutable content version after offline key custody and review are established.

Android official release packaging delegates to the authoritative pack gate. Automatic network content updates remain disabled until persistent anti-rollback/freshness state and atomic activation/recovery are implemented.
