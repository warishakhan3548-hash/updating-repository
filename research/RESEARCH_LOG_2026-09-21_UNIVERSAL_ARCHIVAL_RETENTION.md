# Research Record — Universal Source Vault Archival-Retention Gate — 2026-09-21

Purpose: close the remaining generic durability/licensing gap after the HadeethEnc-specific and denied-retention hardening landed. No Quran/Hadith evidence bytes are added or modified by this change.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---:|---|---|
| fact | Tanzil's Quran Text License permits verbatim copying/distribution under CC BY 3.0 plus source-specific attribution/no-text-change conditions. | https://tanzil.net/docs/Text_License | 2026-09-21 | High | The pinned Tanzil v1.1 snapshot can remain the production Quran Evidence Plane source; durable retention is recorded explicitly instead of being inferred from redistribution alone. |
| fact | Tanzil publishes versioned update history, including Quran text v1.1 and earlier releases. | https://tanzil.net/updates/ | 2026-09-21 | High | Track upstream changes without inventing a legal requirement that every release use upstream latest. |
| fact | QuranEnc republication conditions include updating republished content according to newer issued versions. | https://quranenc.com/en/home/about/terms-and-conditions | 2026-09-21 | High | Keep the existing no-bytes awaiting-licence state until historical retention is independently cleared. |
| fact | HadeethEnc republication conditions likewise include updating according to newer issued versions. | https://hadeethenc.com/en/home/about/terms-and-conditions | 2026-09-21 | High | Preserve the already-landed awaiting-licence/no-bytes gate; current-version republication is not treated as proof of indefinite superseded-snapshot retention. |
| fact | SinaLab's official resources catalogue labels Quran Morphology under CC BY 4.0. | https://sina.birzeit.edu/resources/ | 2026-09-21 | High | Archival retention can be explicitly cleared while exact authorized artifact acquisition and coordinate validation remain separate gates. |
| inference | “May redistribute” and “may retain every historical snapshot indefinitely in a public project mirror” are distinct compliance assertions. | Sources above + project reproducibility requirement | 2026-09-21 | High | Require explicit retention clearance for every capture-ready, preserved or production source. |
| inference | Release freshness is mutable compliance policy, while provenance describes immutable acquisition facts. | Source Vault architecture | 2026-09-21 | High | Keep release requirements in registry/signed release review instead of hashing them into immutable acquisition provenance. |

## Decision

1. Every `awaiting-artifact`, preserved or `production-approved` source must have `historical_snapshot_retention_status=verified-allowed`.
2. `latest_upstream_version_required` is an independent boolean.
3. Existing unresolved/denied state rules remain stricter and unchanged.
4. Acquisition provenance remains immutable and does not absorb later release-policy interpretation.
5. Normal builds remain offline and consume only project-controlled preserved artifacts.
