# Research Log — Capture-Ready Licence Gate — 2026-09-21

## Scope

This review tightens the transition from metadata-only source research to artifact capture. It does not approve, download, mirror, transform, or ship any new Quran, morphology, gloss, Hadith, font, audio, translation, or timing dataset.

## Verified facts

| Type | Claim | Primary source | Verified | Confidence | Product implication |
| --- | --- | --- | --- | --- | --- |
| fact | QUL explicitly tells commercial users to check the licence of each individual resource rather than treating the platform/software licence as blanket permission for datasets. | https://qul.tarteel.ai/faq | 2026-09-21 | High | Availability or a download button cannot authorize Source Vault capture. Unresolved resource rights stay metadata-only. |
| fact | QuranEnc's published republication conditions include source attribution/version requirements, no content modification, and keeping republished content updated to newer source versions. | https://quranenc.com/en/home | 2026-09-21 | High | A source-specific downstream grant must be reviewed across redistribution, commercial use, modification, attribution and historical-retention dimensions before capture. |
| fact | HadeethEnc publishes source-specific republication conditions including attribution/version preservation, no modification and an update-to-newer-source condition. | https://hadeethenc.com/en | 2026-09-21 | High | Hadith availability is not enough to authorize an immutable project-controlled historical mirror. |
| fact | SinaLab's official resource catalogue currently labels its Quran morphology resource CC BY 4.0. | https://sina.birzeit.edu/quran/ | 2026-09-21 | High | QuranMorph can remain an `awaiting-artifact` candidate because the registry records the reviewed capture-authorizing dimensions, while exact artifact acquisition/alignment is still outstanding. |
| fact | CC BY 4.0 grants broad reuse rights only for rights the licensor has authority to license; third-party rights can remain outside that grant. | https://creativecommons.org/licenses/by/4.0/legalcode.en | 2026-09-21 | High | A top-level open-data label must not automatically clear embedded/derived third-party components. |

## Repository finding

The Source Vault already required `historical_snapshot_retention_status=verified-allowed` before a source could use `awaiting-artifact`. However, the generic executable gate did not independently require the other capture-authorizing licence dimensions until snapshot bytes existed or the source reached production approval.

That left an avoidable policy gap: a future acquisition tool could interpret `awaiting-artifact` as permission to download while `redistribution_allowed` or `commercial_use_allowed` was still unknown.

## Decision

Treat `awaiting-artifact` as a strict capture-ready state.

Before that state is valid, the central executable gate requires:

- reviewed source name, exact/pinned version descriptor and licence identifier;
- an absolute HTTPS origin;
- `redistribution_allowed=true`;
- `commercial_use_allowed=true`;
- explicit boolean `modification_allowed`;
- explicit boolean `attribution_required`;
- `historical_snapshot_retention_status=verified-allowed`.

If any of these is unknown, the source remains metadata-only and must not be represented as capture-ready.

The JSON Schema mirrors this conditional rule, but `tools/vault_gate.py` remains the executable authority.

## Current source impact

- QuranMorph remains `awaiting-artifact`; its existing registry entry already declares the required reviewed licence dimensions and historical-retention posture.
- QuranEnc, HadeethEnc, QUL, QAC, MASAQ and EQTB are not promoted by this work.
- No Source Vault artifact bytes, canonical Quran bytes or runtime content packs change in this milestone.

## Non-goals

- no legal conclusion beyond recorded source-specific evidence;
- no source capture;
- no runtime feature or UI change;
- no word-tap activation;
- no Hadith production ingestion.
