# Research Log — Universal Source-Vault Archival Retention — 2026-09-21

Purpose: close a durability/licensing gap where historical-snapshot retention had been enforced only for sources that declared an ongoing latest-version obligation.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---|---|---|
| fact | Tanzil permits verbatim copying/distribution of its Quran text subject to its source-specific attribution/no-modification terms. | https://tanzil.net/docs/Text_License | 2026-09-21 | High | The already-preserved Tanzil v1.1 snapshot may be explicitly marked historical-retention `verified-allowed`; this does not modify its source bytes or archived licence. |
| fact | Tanzil publishes update information separately from the licence grant. | https://tanzil.net/updates/ | 2026-09-21 | High | Archive permission and “must ship latest” are separate dimensions; the registry records `latest_upstream_version_required=false` for the pinned v1.1 evidence snapshot. |
| fact | QuranEnc republication terms require downstream copies to be updated according to newer source versions. | https://quranenc.com/en/home/api | 2026-09-21 | High | Current-version republication does not by itself prove permission to keep superseded public snapshots indefinitely; QuranEnc remains `awaiting-licence` and no bytes may be captured. |
| fact | HadeethEnc republication terms likewise require updating redistributed content to newer versions. | https://hadeethenc.com/en/home | 2026-09-21 | High | HadeethEnc remains metadata-only until historical-retention and commercial-use rights are independently cleared. |
| fact | SinaLab lists QuranMorph under CC BY 4.0. | https://sina.birzeit.edu/quran/ | 2026-09-21 | High | CC BY 4.0 supports preserving and redistributing historical snapshots under its terms; QuranMorph may remain `awaiting-artifact`, but no source bytes are mirrored until an authorized exact artifact is obtained. |
| inference | A durable Source Vault cannot rely on “archival permission only matters when a latest-version clause exists.” | Project durability requirement + sources above | 2026-09-21 | High | Make historical-retention clearance universal before `awaiting-artifact`, preserved bytes, or `production-approved`. |
| architecture | Acquisition-time provenance and current release/admission policy have different lifecycles. | Project source-policy model | 2026-09-21 | High | Keep mutable retention/freshness decisions in registry/policy; do not rewrite immutable acquisition provenance merely to backfill a newly introduced policy dimension. |

## Decision

1. Every source that may advance to artifact acquisition or preservation must explicitly record historical-snapshot retention as `verified-allowed`.
2. `latest_upstream_version_required` becomes an independent boolean. It controls release-time freshness review, not archival permission.
3. `research-candidate` may remain metadata-only without archival clearance; this permits legal/technical investigation without publishing source bytes.
4. `awaiting-licence` remains a hard no-bytes state. `unresolved` retention requires that state.
5. `verified-not-allowed` retention requires `rejected` and cannot preserve source bytes.
6. Runtime pack promotion independently requires a complete Source Vault retention decision, even if registry validation was bypassed.
7. Source-specific acquisition tools must check positive archival clearance before their first network fetch.

No Quran, Hadith, morphology, gloss, canonical, or runtime evidence bytes are changed by this decision.
