# Source Policy

Critical external data must pass every gate before production use:

1. identify origin and exact edition/version;
2. verify redistribution, modification and attribution terms;
3. download the exact artifact;
4. preserve the exact bytes under project control;
5. calculate SHA-256 and file size;
6. preserve a licence/terms snapshot;
7. record machine-readable provenance;
8. build only from the preserved artifact;
9. retain old snapshots when a new version appears;
10. keep an independent backup for critical artifacts where practical.

A normal production build must not fetch an uncontrolled upstream `latest` resource.

## Statuses

- `research-candidate`: useful for evaluation; never consumed by production builds.
- `awaiting-artifact`: licensing appears compatible, but exact bytes are not yet preserved.
- `awaiting-licence`: origin known; storage/redistribution rights are not sufficiently verified.
- `production-approved`: exact artifact, licence snapshot, provenance and checksum are present and validated.
- `rejected`: unsuitable due to trust, licensing or integrity.

Durability never overrides copyright. Only `production-approved` entries may feed release content builders.
