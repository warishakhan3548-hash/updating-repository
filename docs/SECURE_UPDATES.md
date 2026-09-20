# Secure Content Updates

Content packs are versioned independently from the app.

Before activation:

1. verify manifest structure and reject duplicate JSON fields;
2. verify expected pack ID and dependency versions;
3. verify Source Vault, licence, provenance, file SHA-256 and size;
4. verify applicable Quran/Hadith semantic invariants;
5. verify the trusted-key signature threshold over the complete signed manifest;
6. reject rollback below the highest trusted release sequence unless an explicit recovery path is invoked;
7. open the pack read-only and run integrity probes;
8. atomically switch the active-pack pointer;
9. retain the prior verified pack for recovery.

The design follows TUF principles—separate trust metadata, threshold-capable keys, freshness/rollback resistance and recoverability—without claiming a full TUF client before downloadable update distribution exists.

## Current implementation status

Repository publication now has real Ed25519 manifest verification. The signed payload is deterministic, domain-separated and covers the complete manifest except its signature container, including a positive `release_sequence`. The project trust policy supports threshold signatures plus active, retired and revoked keys with bounded release-sequence windows.

Source/provenance, byte-integrity and Quran semantic-fidelity gates run before release-signature authorization. A cryptographically valid signature therefore cannot turn altered sacred content into an accepted pack.

The production trusted-key registry is deliberately empty until an offline release-key ceremony occurs, so no current pack is release-approved.

Android production activation remains fail-closed. The app must independently implement the same manifest verification, persist the highest accepted `release_sequence`, reject rollback, activate atomically and retain a verified recovery pack before `QURAN_PACK_RELEASE_READY` can become true.

A future network-distributed updater should add TUF-style root/targets/snapshot/timestamp metadata and expiry/freeze protection rather than inventing an ad-hoc downloader.
