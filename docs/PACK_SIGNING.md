# Content Pack Signing

Content-pack signatures authenticate an already-reviewed runtime artifact after Source Vault, licence, provenance, checksum, canonical-model and semantic-fidelity validation have passed. A signature never replaces those gates.

## Algorithm choice

Release approval signatures use ECDSA over NIST P-256 (secp256r1), SHA-256, DER-encoded ECDSA signatures stored as base64, and X.509 SubjectPublicKeyInfo public keys stored as base64 in the trusted-key policy.

Manifest algorithm identifier: ecdsa-p256-sha256.

The Android reader currently targets API 24. Android's platform SHA256withECDSA verifier is available far below that minimum, while platform Ed25519 support begins much later. P-256 therefore keeps the future on-device verifier dependency-light.

Private release keys MUST NOT be committed to this repository, CI variables, content packs, the Source Vault, test fixtures, or logs.

## Signed payload

Payload format: aaris-pack-json-v1.

The signature covers the complete manifest except the top-level signature field and is prefixed with the ASCII domain separator AARIS-CONTENT-PACK-SIGNATURE-V1 followed by a newline.

The project-owned canonicalization profile is intentionally small and portable:

- UTF-8;
- no Unicode normalization;
- object keys sorted by Unicode scalar value;
- array order preserved;
- integers only, limited to the cross-runtime safe range;
- floats forbidden;
- deterministic JSON string escaping;
- unpaired Unicode surrogates forbidden.

Because schema-v3 canonical, provenance, toolchain, hashes, dependencies, review status and release_sequence are all ordinary manifest fields, they are all authenticated by the same signature.

This is a restricted project format, not a claim of full RFC 8785/JCS conformance. Any future Android implementation must reproduce these bytes exactly and use golden cross-language vectors.

## Approved manifest

An approved manifest contains review_status=approved, a positive signed release_sequence, and a signature object with status=signed, payload_format=aaris-pack-json-v1, plus one or more signatures containing algorithm=ecdsa-p256-sha256, encoding=base64-der, a fingerprint key_id, and the base64 DER signature value.

release_sequence is the ordering primitive for future rollback protection. Repository validation requires it to be a positive integer for approved packs.

Persistent device-side highest-sequence state is NOT implemented yet. Bundled Android releases are protected at build time; downloadable content activation still needs an on-device verifier plus persisted anti-rollback state.

## Trusted public-key policy

policy/trusted_pack_keys.json is the repository trust root for content-pack release public keys.

Each enrolled key contains:

- key_id: sha256: plus the SHA-256 of DER SubjectPublicKeyInfo bytes;
- algorithm = ecdsa-p256-sha256;
- status: active, retired, or revoked;
- public_key_spki_base64;
- optional allowed_pack_ids;
- optional min_release_sequence / max_release_sequence.

The policy also defines signature_threshold. Duplicate signatures from the same key count once.

Meaning:

- active: may validate releases within its declared scope/window;
- retired: retained for historical verification within its sequence window;
- revoked: never counts;
- pack scopes compartmentalize a key so a Quran key need not automatically authorize a Hadith pack.

The verifier recomputes each public key's fingerprint and rejects a policy entry whose bytes do not match its key_id.

## Rotation and compromise

Normal rotation:

1. generate the new private key on an offline/controlled signing machine;
2. independently record its public-key fingerprint;
3. review and commit only the public key and scope as active;
4. issue a higher signed release_sequence;
5. after migration, mark the previous key retired and constrain its maximum sequence where practical;
6. keep historical public keys while old releases must remain verifiable.

Compromise response:

1. mark the compromised key revoked;
2. enroll a new reviewed public key;
3. issue a higher release sequence;
4. require future clients to reject revoked keys and lower accepted sequences.

Trusted-key policy changes are security-sensitive code-review events.

## Android bundled-release boundary

Debug builds may use the pinned candidate pack.

Release packaging first requires review_status=approved, then invokes tools/pack_gate.py. The gate validates Source Vault provenance, runtime/canonical semantics and the trusted-key signature before Gradle can produce a release artifact.

The release APK does not need Python at runtime. Future downloaded content packs are different: they require native/on-device signature verification before activation.

## Current state

The verifier and adversarial tests exist, but policy/trusted_pack_keys.json intentionally contains no production public key yet. Therefore the threshold cannot be met and no pack can currently become approved.

Do not generate a production private key inside CI merely to make a green build.

The currently published Quran pack remains an unsigned candidate. Promotion must use a new immutable content version after content review and an explicit offline key ceremony; never rewrite an old candidate's bytes in place.
