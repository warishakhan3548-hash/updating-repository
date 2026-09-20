# Research Record — Universal Source Vault archival retention — 2026-09-21

Purpose: close the remaining generic source-admission gap after source-specific QuranEnc/HadeethEnc hardening. No Quran/Hadith evidence bytes are added or modified.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---|---|---|
| fact | Tanzil permits verbatim copying/distribution of its Quran text under CC BY 3.0 plus source-specific attribution/no-change conditions and publishes an update path. | https://tanzil.net/docs/Text_License | 2026-09-21 | High | Keep the pinned v1.1 source production-approved and record historical-retention clearance explicitly. |
| fact | SinaLab's official catalogue labels Quran Morphology as CC-BY-4.0. | https://sina.birzeit.edu/resources/ | 2026-09-21 | High | Archival use is licence-compatible in principle; exact authorized bytes and coordinate alignment remain separate blockers. |
| fact | QuranEnc and HadeethEnc republication terms require downstream copies to update according to newer source versions. | official QuranEnc/HadeethEnc terms | 2026-09-21 | High | Current-version republication does not alone prove indefinite public retention of superseded snapshots; both remain metadata-only while archival permission is unresolved. |
| inference | Redistributable-now and retain-old-versions-indefinitely are separate compliance facts under the project's reproducibility requirement. | sources above + project policy | 2026-09-21 | High | Require an explicit retention decision before capture for every source, not only sources with stay-current terms. |
| inference | Release freshness can change without changing what bytes were acquired. | Source Vault architecture | 2026-09-21 | High | Keep release requirements in registry/manifest policy and out of immutable acquisition provenance. |

## Decision

- `verified-allowed` archival retention is required before `awaiting-artifact`, preservation or production.
- `unresolved` archival retention requires `awaiting-licence`.
- `verified-not-allowed` archival retention requires `rejected`.
- `awaiting-licence` and `rejected` preserve no project-controlled source bytes.
- `latest_upstream_version_required` is an independent boolean and triggers a signed release freshness review only when true.

This hardening changes policy/state-machine enforcement only. It does not modify Quran source text, canonical Quran bytes, runtime packs, Hadith evidence, or user data.
