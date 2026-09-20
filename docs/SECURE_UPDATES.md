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

Repository/build-time trusted-key cryptographic verification is implemented with Ed25519 after Source Vault, provenance, canonical and semantic-fidelity gates. Approved manifests must carry authenticated release-ordering metadata and satisfy the threshold in `policy/trusted_pack_keys.json`.

The production trusted-key policy intentionally contains **no release public keys yet**, so no current pack can become `approved`. Private release keys remain outside Git and require a separate offline key ceremony.

This is not yet a complete network update client. Device-side rollback state, freshness/freeze resistance, trust-root rotation, atomic activation/recovery and min-API-compatible Android signature verification remain explicit future work. The current Android release gate therefore stays fail-closed.
