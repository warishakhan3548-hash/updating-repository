# Source Policy

Critical external data must pass every gate before production use:

1. identify origin and exact edition/version;
2. verify redistribution, commercial-use, modification and attribution terms;
3. download the exact artifact;
4. preserve the exact bytes under project control;
5. calculate SHA-256 and file size;
6. preserve a licence/terms snapshot;
7. record machine-readable provenance;
8. build only from the preserved artifact;
9. retain old snapshots when a new version appears;
10. keep an independent backup for critical artifacts where practical.

A normal production build must not fetch an uncontrolled upstream `latest` resource.

When a legally cleared upstream release is inherently multi-file, preserve the exact members and bind them with a project-controlled checksum ledger rather than concatenating or normalizing source bytes. The ledger becomes the stable Source Vault artifact root; its members are still verified individually before promotion.

## Statuses

- `research-candidate`: useful for evaluation; never consumed by production builds.
- `awaiting-artifact`: capture-authorizing licence review is complete—redistribution and commercial use are verified, modification/attribution obligations are explicit, historical retention is verified allowed—but the exact artifact bytes are not yet preserved.
- `awaiting-licence`: origin known; storage/redistribution rights are not sufficiently verified.
- `production-approved`: exact artifact, licence snapshot, provenance and checksum are present and validated.
- `rejected`: unsuitable due to trust, licensing or integrity.

Durability never overrides copyright. Only `production-approved` entries may feed release content builders.

## Commercial-use gate

Redistribution permission and commercial-use permission are separate licence dimensions. A dataset may be legal to copy for research or non-commercial use while still being ineligible for a production release. The registry therefore records `commercial_use_allowed` independently.

A `production-approved` source must set `commercial_use_allowed: true`. Unknown or false values fail closed in Source Vault validation, and the runtime pack gate checks the same condition again before any pack can ship. Do not infer commercial rights from popularity, repository visibility, a code licence, or redistribution permission.

## Archival-retention gate

Redistribution permission and historical-retention permission are separate review dimensions. Before any source may become `awaiting-artifact`, the central Source Vault gate now also requires a reviewed source identity/version/licence, an absolute HTTPS origin, `redistribution_allowed=true`, `commercial_use_allowed=true`, explicit modification/attribution flags, and `historical_snapshot_retention_status=verified-allowed`. If any capture-authorizing licence dimension remains unresolved, the source stays metadata-only as `awaiting-licence`; an explicit historical-retention denial stays metadata-only as `rejected`. The same retention clearance remains mandatory for preserved snapshots and `production-approved` entries.

A source-specific term that requires republishers to remain on the latest upstream version is **not automatically compatible** with a public immutable historical Source Vault, but the archival check is universal rather than limited to “stay current” sources. Acquisition tooling must fail closed before network download when the registry has not cleared the source for capture. `latest_upstream_version_required` is a separate boolean release-time obligation.

If archival retention is explicitly verified **not allowed**, the source must be `rejected` for public Source Vault preservation and must remain metadata-only. This is distinct from `unresolved`: unresolved rights may later be clarified, while a verified denial is an explicit stop condition unless the legal basis changes and is re-reviewed.

## Release-time source obligations

Archival permission and current redistribution eligibility are separate questions. Once archival retention has been legally cleared, a preserved source snapshot remains immutable for reproducibility even when its licence also imposes an ongoing release-time obligation such as “use/update to the latest upstream version”.

Such obligations are recorded as machine-readable `release_requirements` in the Source Vault registry. Normal offline builds do **not** contact upstream and historical candidate packs do not expire with wall-clock time. Instead, an `approved` pack from a source that requires the latest upstream version must carry a `source_release_review` that binds the source ID/version, exact archived licence hash, official version-check URL, review timestamp, and the observed upstream version. The final pack gate requires the observed version to equal the preserved source version. Because the review object is part of the manifest outside the signature block, release signatures authenticate that review together with the pack.

This is deliberately a release-approval control, not a claim that the build system can infer legal compliance automatically. The review must be performed against the official source as part of the release review; if upstream has advanced, preserve the new version as a new Source Vault snapshot instead of overwriting the old one.
