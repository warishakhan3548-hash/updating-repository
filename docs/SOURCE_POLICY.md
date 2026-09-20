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

## Release-time source obligations

Archival permission and current redistribution eligibility are separate questions. A preserved source snapshot remains immutable for reproducibility even when its licence imposes an ongoing release-time obligation such as “use/update to the latest upstream version”.

Such obligations are recorded as machine-readable `release_requirements` in the Source Vault registry. Normal offline builds do **not** contact upstream and historical candidate packs do not expire with wall-clock time. Instead, an `approved` pack from a source that requires the latest upstream version must carry a `source_release_review` that binds the source ID/version, exact archived licence hash, official version-check URL, review timestamp, and the observed upstream version. The final pack gate requires the observed version to equal the preserved source version. Because the review object is part of the manifest outside the signature block, release signatures authenticate that review together with the pack.

This is deliberately a release-approval control, not a claim that the build system can infer legal compliance automatically. The review must be performed against the official source as part of the release review; if upstream has advanced, preserve the new version as a new Source Vault snapshot instead of overwriting the old one.

## Archival-retention gate

A source-specific rule requiring republishers to remain on the latest upstream version is not automatically compatible with a public immutable historical Source Vault. If indefinite redistribution of superseded snapshots is not clearly permitted, keep the source `awaiting-licence` even if a current-version review-only capture exists. Such captured bytes remain non-production evidence: they are not registered as the production `vault_artifact`, no runtime pack may consume them, and a signed current-version review cannot override the unresolved archival-rights blocker.

If permission is later verified, record `historical_snapshot_retention_status: verified-allowed`, bind the exact candidate artifact/licence/provenance into the Source Vault registry, run integrity review, and only then consider production promotion. If permission is denied, redesign around a legally compatible source or distribution model rather than weakening reproducibility requirements.
