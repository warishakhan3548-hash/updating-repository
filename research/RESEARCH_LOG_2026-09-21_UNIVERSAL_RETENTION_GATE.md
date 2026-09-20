# Research Log — Universal Source Vault Archival-Retention Gate — 2026-09-21

Purpose: close a generic durability/licensing gap found while re-auditing the live Source Vault. No Quran, Hadith, morphology or gloss evidence bytes are added or modified by this change.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---|---|---|
| fact | Tanzil permits verbatim copying/distribution of its Quran text with source/link requirements and forbids changing the Quran text. | https://tanzil.net/docs/Text_License | 2026-09-21 | High | The pinned Tanzil v1.1 bytes can remain an immutable Source Vault snapshot; record archival clearance explicitly instead of inferring it from status. |
| fact | Tanzil maintains a versioned update log and identifies v1.1 as released on 2021-02-12. | https://tanzil.net/updates/ | 2026-09-21 | High | Upstream changes can be monitored without treating “latest” as a mandatory release rule when the archived terms do not impose one. |
| fact | QuranEnc permits republication subject to conditions including updating republished content according to the latest source version. | https://quranenc.com/en/home/about/terms-and-conditions | 2026-09-21 | High | Current-version republication does not by itself establish indefinite public retention of superseded snapshots; keep archival status unresolved and block capture. |
| fact | HadeethEnc publishes the same kind of latest-version update condition for republished content, and its version checker currently reports Arabic v1.7.0. | https://hadeethenc.com/en/ ; https://hadeethenc.com/en/check/ar/v1.3.0 | 2026-09-21 | High | Keep HadeethEnc metadata-only until archival and commercial-use rights are independently cleared. |
| fact | SinaLab labels its Quran Morphology resource CC BY 4.0. | https://sina.birzeit.edu/resources/ | 2026-09-21 | High | The declared licence supports durable archival copying in principle, but exact authorized artifact acquisition and coordinate validation remain separate gates. |
| fact | CC BY 4.0 permits reproduction/sharing for any purpose, including commercial use, and states the grant is irrevocable while terms are followed. | https://creativecommons.org/licenses/by/4.0/ | 2026-09-21 | High | Treat historical retention and release freshness as separate facts rather than conflating them. |
| fact | QAC's download page presents GPL/verbatim-copy language while its FAQ limits downloaded research data to non-commercial research. | https://corpus.quran.com/download/ ; https://corpus.quran.com/faq.jsp | 2026-09-21 | High | Keep QAC blocked; this change does not reinterpret its conflicting source-specific terms. |
| inference | Permission to redistribute a current artifact and permission to retain every historical public snapshot indefinitely are distinct compliance questions. | primary sources above + project reproducibility requirement | 2026-09-21 | High | Require an explicit archival-retention decision before capture/preservation/production. |
| inference | Freshness/latest-version review is mutable release policy, while acquisition provenance is an immutable description of captured bytes and archived terms. | Source Vault architecture | 2026-09-21 | High | Keep the decision in the registry/signed release review; do not rewrite old provenance solely to add a later policy judgment. |

## Decision

1. Every source in `awaiting-artifact`, every source with preserved snapshot metadata, and every `production-approved` source must record `historical_snapshot_retention_status=verified-allowed`.
2. `latest_upstream_version_required` is an independent boolean.
3. Production pack validation always requires archival clearance. A signed `source_release_review` is required only when the source also requires the latest upstream version.
4. Source-specific acquisition tooling must fail before its first network request when archival clearance is absent.
5. Immutable acquisition provenance is not rewritten merely to backfill a later registry-level legal/release decision.

## Current source decisions

- Tanzil Quran Text v1.1: archival retention `verified-allowed`; latest-version release review not mandatory.
- QuranMorph 2025 candidate: archival retention `verified-allowed` under the declared CC BY 4.0 licence; exact authorized artifact still missing.
- QuranEnc As-Siraj v1.0.0: archival retention `unresolved`; capture remains blocked.
- HadeethEnc Arabic v1.7.0 observed: archival retention `unresolved`; capture remains blocked.
- QAC/QUL candidates: unchanged and not promoted.

This is a conservative engineering gate, not a substitute for legal advice or source-specific review.
