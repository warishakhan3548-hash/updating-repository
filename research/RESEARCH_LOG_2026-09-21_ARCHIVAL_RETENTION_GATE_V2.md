# Research Record — Universal Source Vault Archival-Retention Gate — 2026-09-21

Purpose: close a generic durability/licensing gap without adding or modifying Quran/Hadith evidence bytes.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---|---|---|
| fact | Tanzil permits verbatim copying/distribution of its Quran text under CC BY 3.0 plus source-specific attribution/no-change conditions and publishes an update path. | https://tanzil.net/docs/Text_License | 2026-09-21 | High | Keep the pinned Tanzil v1.1 snapshot production-approved; record archival clearance explicitly instead of inferring it only from source status. |
| fact | SinaLab's official resource catalogue labels Quran Morphology as CC-BY-4.0. | https://sina.birzeit.edu/resources/ | 2026-09-21 | High | Archival redistribution is licence-compatible in principle, but exact authorized bytes and coordinate alignment are still required before production. |
| fact | QuranEnc's published republication terms require downstream content to be updated according to newer source versions. | https://quranenc.com/en/home/about/terms-and-conditions | 2026-09-21 | High | Current-version republication does not by itself prove indefinite public retention of superseded snapshots; remain awaiting-licence. |
| fact | HadeethEnc's published republication conditions likewise require updates according to newer source versions. | https://hadeethenc.com/en/home/about/terms-and-conditions | 2026-09-21 | High | Keep HadeethEnc metadata-only and awaiting-licence until historical retention is clarified. |
| inference | “May redistribute” and “may preserve every historical version indefinitely” are distinct compliance questions under this project's reproducibility requirement. | sources above + Source Vault policy | 2026-09-21 | High | Make archival retention a universal admission gate before capture, not a source-specific exception. |
| inference | Release freshness is mutable policy, while acquisition provenance describes immutable captured bytes. | project architecture | 2026-09-21 | High | Do not rewrite historical provenance merely to add or change a later release obligation. |

## Decision

Every source that is `awaiting-artifact`, has any preserved snapshot metadata, or is `production-approved` must have `historical_snapshot_retention_status=verified-allowed`. An `awaiting-licence` entry is a hard metadata-only state.

`latest_upstream_version_required` is an independent boolean. When true, approved packs still require the source-bound freshness review already defined by the release gate. When false, archival clearance remains required but no artificial “latest” attestation is introduced.

No Quran/Hadith source bytes, canonical Quran bytes, runtime pack bytes, or user data are changed by this hardening pass.
