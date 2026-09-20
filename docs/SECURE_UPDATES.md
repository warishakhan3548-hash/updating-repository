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

Hash and provenance validation are implemented, but trusted-key cryptographic signature verification is not yet implemented. Therefore the content-pack gate deliberately rejects every manifest marked `approved`, even when signature-shaped fields are present. This prevents unsigned or fake-signed content from crossing the production Reader activation boundary.

The next signing milestone must define the signed payload/canonicalization, trusted public-key storage, key IDs and rotation, verification algorithm, rollback metadata, and regression tests before any pack may be promoted to `approved`.
