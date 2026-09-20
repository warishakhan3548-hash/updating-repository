# Secure Content Updates

Content packs are versioned independently from the app.

Before activation:

1. verify manifest schema;
2. verify expected pack ID and dependency versions;
3. verify cryptographic signature;
4. verify file SHA-256 and size;
5. reject rollback below the trusted version unless an explicit recovery path is invoked;
6. open the pack read-only and run integrity probes;
7. atomically switch the active-pack pointer;
8. retain the prior verified pack for rollback.

The design follows TUF principles—trusted metadata, freshness, integrity and rollback resistance—without importing unnecessary machinery before real update distribution exists.

## Current implementation status

Hash/provenance validation and trusted-key cryptographic approval verification are implemented. Approved manifests require ECDSA P-256/SHA-256 signatures over the complete manifest except the signature block, a positive signed `release_sequence`, and a trusted public key that satisfies the repository threshold/scope/sequence policy.

The production key policy is intentionally empty today, so approval still fails closed until an offline key ceremony enrolls reviewed public keys. Bundled Android release packaging invokes the same repository pack gate before a release artifact can be produced.

Persistent **device-side** anti-rollback state, freshness/expiry metadata, native verification for downloaded packs, atomic activation and recovery policy are not yet implemented. Those remain mandatory before network-delivered content updates are enabled.
