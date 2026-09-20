# Source Policy

Critical external data must pass every gate before production use:

1. identify origin and exact edition/version;
2. verify redistribution, commercial-use, modification, attribution and historical-retention rights;
3. download the exact artifact;
4. preserve the exact bytes under project control;
5. calculate SHA-256 and file size;
6. preserve a licence/terms snapshot;
7. record machine-readable provenance;
8. build only from the preserved artifact;
9. retain old snapshots when a new version appears;
10. keep an independent backup for critical artifacts where practical.

A normal production build must not fetch an uncontrolled upstream `latest` resource.

**Historical retention is a universal preservation gate.** A source may enter `awaiting-artifact`, preserve bytes, or become `production-approved` only when the registry explicitly records `historical_snapshot_retention_status=verified-allowed`. Generic redistribution permission is not treated as proof that superseded snapshots may remain in a public immutable archive.

When a legally cleared upstream release is inherently multi-file, preserve the exact members and bind them with a project-controlled checksum ledger rather than concatenating or normalizing source bytes. The ledger becomes the stable Source Vault artifact root; its members are still verified individually before promotion.

## Statuses

- `research-candidate`: useful for evaluation; never consumed by production builds.
- `awaiting-artifact`: licensing and historical retention are explicitly cleared for capture, but exact bytes are not yet preserved.
- `awaiting-licence`: origin known; storage/redistribution rights are not sufficiently verified.
- `production-approved`: exact artifact, licence snapshot, provenance and checksum are present and validated.
- `rejected`: unsuitable due to trust, licensing or integrity.

Durability never overrides copyright. Only `production-approved` entries may feed release content builders.

## Commercial-use gate

Redistribution permission and commercial-use permission are separate licence dimensions. A dataset may be legal to copy for research or non-commercial use while still being ineligible for a production release. The registry therefore records `commercial_use_allowed` independently.

A `production-approved` source must set `commercial_use_allowed: true`. Unknown or false values fail closed in Source Vault validation, and the runtime pack gate checks the same condition again before any pack can ship. Do not infer commercial rights from popularity, repository visibility, a code licence, or redistribution permission.

## Archival-retention gate

A source-specific term that requires republishers to remain on the latest upstream version is **not automatically compatible** with a public immutable historical Source Vault. If the project must retain old snapshots for reproducibility but the licence does not clearly permit continued archival redistribution of those older versions, keep the source `awaiting-licence` until written clarification, a compatible archival grant, or a replacement source resolves the conflict. Acquisition tooling must fail closed before network download when the registry has not cleared the source for capture. The executable Source Vault gate also rejects preserved snapshot fields on `awaiting-licence` entries and rejects `unresolved` historical-retention requirements under any less restrictive status, so repository metadata and captured bytes cannot drift away from this policy.

If archival retention is explicitly verified **not allowed**, the source must be `rejected` for public Source Vault preservation and must remain metadata-only. This is distinct from `unresolved`: unresolved rights may later be clarified, while a verified denial is an explicit stop condition unless the legal basis changes and is re-reviewed.

## Release-time source obligations

Archival permission and current redistribution eligibility are separate questions. Once archival retention has been legally cleared, a preserved source snapshot remains immutable for reproducibility even when its licence also imposes an ongoing release-time obligation such as “use/update to the latest upstream version”.

These decisions are recorded as machine-readable `release_requirements` in the Source Vault registry. `historical_snapshot_retention_status` answers whether the exact snapshot may remain archived; `latest_upstream_version_required` independently answers whether a release must re-check upstream freshness. A source such as Tanzil can therefore have verified archival retention without a mandatory latest-version release review.

Normal offline builds do **not** contact upstream and historical candidate packs do not expire with wall-clock time. When `latest_upstream_version_required=true`, an `approved` pack must carry a `source_release_review` that binds the source ID/version, exact archived licence hash, official version-check URL, review timestamp, and the observed upstream version. When it is false, that release review is rejected as unnecessary.

Acquisition provenance remains an immutable description of the bytes originally captured and the archived terms used at acquisition time. Later registry-level legal/release interpretations are not backfilled into old provenance files merely to satisfy a new policy dimension.

This is deliberately a release-approval control, not a claim that the build system can infer legal compliance automatically. The review must be performed against the official source as part of the release review; if upstream has advanced, preserve the new version as a new Source Vault snapshot instead of overwriting the old one.
