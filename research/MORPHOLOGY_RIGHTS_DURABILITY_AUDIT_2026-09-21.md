# Morphology Rights & Durability Audit — 2026-09-21

## Scope

This note records source-governance findings only. It does **not** approve new Evidence Plane bytes and it does not change Quran text, runtime content packs, Android search, reader behavior, or user learning state.

## Verified findings

| Claim | Primary source checked | Confidence | Licence / durability implication | Product implication |
| --- | --- | --- | --- | --- |
| Quranic Arabic Corpus v0.4 has conflicting official licence signals: the download page presents GNU GPL/verbatim-copy conditions while the FAQ describes use as non-commercial research. | https://corpus.quran.com/download/ and https://corpus.quran.com/faq.jsp | High | Commercial redistribution and long-term mirror rights are not sufficiently clear for this project. | Keep QAC metadata-only and `awaiting-licence`; do not mirror bytes. |
| QUL says commercial use depends on the licence terms of each individual resource. | https://qul.tarteel.ai/faq | High | The QUL software repository licence is not blanket permission for resource datasets. | Word lemma/root and WBW resources remain blocked until resource-specific rights are verified. |
| QUL word-root resource 76 exposes a downloadable SQLite artifact but its inspected resource page does not state a dataset licence. | https://qul.tarteel.ai/resources/morphology/76 | High | Availability is not the same as redistribution permission. | Do not capture the artifact merely because a download exists. |
| Quran Foundation Developer Terms impose storage/redistribution constraints that do not fit a permanent project-controlled critical-source mirror. | https://api-docs.quran.foundation/legal/developer-terms/ | High | A permanent reproducibility mirror is not supported by the inspected terms. | Keep the API rejected as a critical Source Vault foundation; it may remain a separately evaluated optional online integration. |
| MASAQ Mendeley Data version 5 is labelled CC BY 4.0, while the same dataset record later changed version 6 to CC BY-NC 3.0. | https://data.mendeley.com/datasets/9yvrzxktmr/5 and https://data.mendeley.com/datasets/compare/9yvrzxktmr | High | The historical v5 licence is promising, but the later licence change creates a version-specific rights-chain question that must be resolved before capture. | Register v5 as metadata-only `awaiting-licence`; do not mirror bytes yet. |
| CC BY 4.0 grants are designed to be irrevocable while terms are followed, but only cover rights the licensor has authority to grant. | https://creativecommons.org/licenses/by/4.0/legalcode.en | High | A later licence change does not by itself prove the historical grant vanished, but third-party embedded content still requires a rights-chain review. | Do not infer that MASAQ's licence automatically grants downstream rights over every embedded/source-text element. |

## Architectural inference

The immediate blocker for trusted word tap is no longer lack of candidate datasets; it is **clear, durable, version-specific downstream rights plus exact-coordinate alignment**. The Source Vault should therefore force every actionable source state to record whether immutable historical retention is allowed, unresolved, or denied.

A missing retention field is not a safe state. The gate now permits omission only for lightweight `research-candidate` entries that have not yet been promoted into an actionable acquisition/licensing workflow.

## Experimental hypothesis

MASAQ v5 may be a useful morphology source if a future rights-chain review establishes that:

1. the exact v5 files are covered for redistribution/commercial use;
2. embedded or derived third-party material is within that grant or can be excluded;
3. immutable historical retention is permitted;
4. the exact artifact can be captured under project control;
5. chapter:verse:word coordinates align deterministically with the canonical Tanzil Evidence Plane.

Until all five hold, MASAQ is not production-ready and no bytes should enter the Source Vault.

## This run

- No external dataset bytes were downloaded or mirrored.
- No production source was promoted.
- QAC, QUL, Quran Foundation and MASAQ now have explicit historical-retention posture in the registry.
- CI should fail if an `awaiting-licence` or `rejected` source silently omits that posture.
