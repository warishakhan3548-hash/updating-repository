# Research Record — Universal Source Vault archival retention — 2026-09-21

Purpose: close the remaining generic admission gap after QuranEnc/HadeethEnc-specific hardening. No Quran/Hadith evidence bytes are added or modified.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---|---|---|
| fact | Tanzil permits verbatim copying/distribution of its Quran text under CC BY 3.0 plus source-specific attribution/no-change conditions and publishes an update path. | https://tanzil.net/docs/Text_License | 2026-09-21 | High | Keep v1.1 production-approved and record archival clearance explicitly. |
| fact | SinaLab's official resource catalogue labels Quran Morphology as CC-BY-4.0. | https://sina.birzeit.edu/resources/ | 2026-09-21 | High | The source may remain capture-ready in principle, but exact authorized bytes and coordinate alignment are separate blockers. |
| fact | QuranEnc and HadeethEnc republication terms include obligations to update downstream copies according to newer source versions. | official QuranEnc/HadeethEnc terms | 2026-09-21 | High | Their superseded-snapshot retention remains unresolved, so both stay metadata-only. |
| inference | Permission to redistribute a current version and permission to preserve superseded public snapshots indefinitely are separate compliance facts under this project's reproducibility requirement. | sources above + project policy | 2026-09-21 | High | Require an explicit retention decision before capture for every source. |
| inference | Release freshness can change without changing which bytes were acquired. | Source Vault architecture | 2026-09-21 | High | Keep mutable release requirements out of immutable acquisition provenance. |

## Decision

- `verified-allowed` archival retention is required before `awaiting-artifact`, preservation, or production.
- `unresolved` archival retention remains `awaiting-licence`.
- `verified-not-allowed` archival retention remains `rejected`.
- `latest_upstream_version_required` is independent and triggers a signed freshness review only when true.
- QuranEnc acquisition checks retention before its first network request.

This pass changes only policy/state-machine enforcement, registry review metadata and tests/documentation. Quran source text, canonical Quran bytes, runtime packs, Hadith evidence and user data are unchanged.
