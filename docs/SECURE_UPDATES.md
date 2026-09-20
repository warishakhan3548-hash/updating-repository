# Secure Content Updates

Content packs are versioned independently from the app.

Before activation:

1. verify manifest schema and unambiguous JSON parsing;
2. verify expected pack ID and dependency versions;
3. verify Source Vault, provenance and semantic/canonical integrity;
4. verify the trusted release signature;
5. verify file SHA-256 and size;
6. reject rollback below persistent trusted sequence/freshness state unless an explicit recovery path is invoked;
7. open the pack read-only and run integrity probes;
8. atomically switch the active-pack pointer;
9. retain the prior verified pack for recovery.

The design follows TUF principles—trusted metadata, integrity, version ordering and rollback resistance—without importing unnecessary update machinery before remote distribution exists.

## Current implementation status

Source Vault, licence/provenance, file integrity, canonical-v3 binding and importer-independent Quran semantic validation are implemented. Trusted-key authenticity is implemented for `approved` manifests in `tools/pack_signatures.py`.

Signature format `aaris-pack-signature-v2` uses Ed25519 over a domain-separated deterministic manifest payload. The signed payload includes a positive `release_sequence`, while floats, unsafe cross-runtime integers, duplicate JSON object keys and invalid Unicode scalar values fail closed.

Release key IDs are SHA-256 fingerprints of the canonical public-key descriptor. The project trust policy supports thresholds plus `active`, `retired` and `revoked` key states. Active and retired keys are bounded by signed release-sequence authorization windows; retired keys require a finite historical ceiling and revoked keys never authorize a release.

The repository trust root remains deliberately `bootstrap-required`: no production release public key has been enrolled and no private signing key is stored in GitHub. Current Quran packs therefore remain unsigned candidates.

## Still blocked before automatic network updates

A signed sequence is an ordering primitive, not persistent device anti-rollback by itself. Automatic remote pack updates remain disabled until the app stores the highest accepted sequence/freshness state, tests atomic activation/recovery, and has a reviewed trust-root rotation/revocation procedure.

Bundled official Android releases may use the repository pack gate during build, but on-device remote content activation is not claimed yet.
