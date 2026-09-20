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

Hash/provenance validation and trusted-key Ed25519 signature verification are implemented. Approved manifests must carry a positive signed `release_sequence` and satisfy the threshold in `policy/trusted_pack_keys.json`. See `PACK_SIGNING.md`.

The trusted-key policy currently contains **no production public keys**, so the threshold cannot yet be met. This is intentional: a production private key must be generated and protected outside Git, and only its reviewed public key may be enrolled.

Device-side persistence of the highest accepted `release_sequence`, atomic activation and explicit recovery/rollback handling remain future runtime work. The build gate validates signed ordering metadata but does not pretend to provide device state it does not own.
