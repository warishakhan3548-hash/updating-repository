# Research Record — Universal Source Vault Archival-Retention Gate — 2026-09-21

Purpose: close a generic durability/licensing gap discovered while re-auditing the live Source Vault. No Quran/Hadith evidence bytes are added or modified by this change.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---:|---|---|
| fact | Tanzil's Quran Text License permits verbatim copying/distribution under CC BY 3.0 plus source-specific attribution/no-text-change conditions. | https://tanzil.net/docs/Text_License | 2026-09-21 | High | The pinned Tanzil v1.1 snapshot can remain the production Quran Evidence Plane source; historical retention is recorded explicitly instead of being inferred from generic redistribution alone. |
| fact | Tanzil publishes a versioned update history, including Quran text v1.1 and earlier releases. | https://tanzil.net/updates/ | 2026-09-21 | High | Track upstream updates without making “latest” a legal release requirement when the archived terms do not impose one. |
| fact | QuranEnc permits republication subject to conditions that include updating republished content according to the latest issued version. | https://quranenc.com/en/home/about/terms-and-conditions | 2026-09-21 | High | Current-version republication does not by itself prove indefinite public retention of superseded snapshots; keep arabic_seraj blocked until archival retention is clarified. |
| fact | HadeethEnc's published republication conditions likewise include updating according to the latest issued version. | https://hadeethenc.com/en/home/about/terms-and-conditions | 2026-09-21 | High | Do not promote HadeethEnc into the immutable Hadith Evidence Plane until historical-retention rights and edition/numbering provenance are separately cleared. |
| inference | “May redistribute” and “may keep every historical version publicly mirrored indefinitely” are distinct compliance facts. | Sources above + project reproducibility requirement | 2026-09-21 | High | Make historical-retention clearance a universal pre-capture/preservation gate, not a QuranEnc-specific exception. |
| inference | Freshness/latest-version review is mutable release policy, whereas acquisition provenance is an immutable description of captured bytes. | Source Vault architecture | 2026-09-21 | High | Keep `release_requirements` in the registry and signed release review; do not hash mutable release interpretation into immutable acquisition provenance. |

## Decision

1. Every `awaiting-artifact`, preserved, or `production-approved` source must declare `release_requirements` with `historical_snapshot_retention_status=verified-allowed`.
2. `latest_upstream_version_required` becomes an explicit boolean, so archival permission is not conflated with a latest-version obligation.
3. Production pack validation always checks historical-retention clearance. A signed `source_release_review` is required only when `latest_upstream_version_required=true`.
4. Acquisition tooling must check archival clearance before its first network request.
5. Mutable release/freshness obligations are not copied into acquisition provenance.

## Non-goals

- no new Quran, morphology, gloss or Hadith dataset;
- no change to Tanzil source bytes, hashes, canonical Quran JSONL or runtime Quran SQLite;
- no claim that QuranEnc/HadeethEnc historical archival redistribution has been cleared;
- no legal opinion beyond enforcing the project's conservative fail-closed policy.
