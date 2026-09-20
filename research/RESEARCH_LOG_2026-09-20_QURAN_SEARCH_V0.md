# Research Record — Strict Local Quran Search Baseline — 2026-09-20

This record documents the narrow research and implementation decision for the first Android Quran-search slice. It introduces no new external evidence source and does not alter any Source Vault artifact or Quran display text.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---:|---|---|
| fact | SQLite FTS5 offers richer tokenization and ranking facilities such as BM25 and trigram tokenization. | https://sqlite.org/fts5.html | 2026-09-20 | High | Keep FTS5 as an evaluated future lane; do not require it for the first 6,236-row Android baseline. |
| fact | Android's platform SQLite implementation depends on the Android release rather than one application-pinned SQLite version. | https://developer.android.com/reference/android/database/sqlite/package-summary | 2026-09-20 | High | Avoid making first-search correctness depend on version-varying FTS behavior across the current minSdk range. |
| fact | Unicode normalization defines NFC canonical composition. | https://www.unicode.org/reports/tr15/ | 2026-09-20 | High | Mirror the existing quran-core NFC query lane on Android while rendering only source-faithful original Arabic. |
| finding | quran-core 1.1.0 already contains provenance-bound `search_unicode` and `search_diacritic_free` fields produced by `arabic-search-v1`; the Android reader previously did not expose them. | repository audit | 2026-09-20 | High | Reuse existing derived lanes rather than creating a second search database or changing content-pack bytes. |
| inference | For 6,236 ayah rows, a debounced read-only substring baseline is a safer first vertical slice than prematurely adding fuzzy dependencies before a labelled search golden set exists. | source + repository synthesis | 2026-09-20 | High | Implement strict deterministic search now; add fuzzy/FTS re-ranking only after measured retrieval evaluation. |

## Decision

Implement one Android-owned query normalizer matching the pinned `arabic-search-v1` contract and require the pack metadata version to match before searching.

The first lane:

- normalizes the query to NFC;
- derives the same diacritic-free query representation used by the content builder;
- searches the existing read-only Quran pack with literal SQLite `instr` containment;
- ranks exact and prefix matches ahead of broader contained matches;
- returns only canonical ayah coordinates plus `original_text`;
- displays **No reliable match found** for an empty result set;
- performs no fuzzy, conceptual, morphology, root, translation or AI expansion.

This is intentionally an ayah retrieval baseline, not a claim that Quran search is complete.

## Trust boundary

Search normalization is derived data. It may select an ayah, but it never becomes display evidence. Result rendering continues to use only `quran_ayah.original_text`.

No TokenID, LexemeID, SenseID, morphology or contextual gloss is manufactured by this feature.

## Evaluation follow-up

Before introducing fuzzy ranking, create the labelled golden set already specified in `docs/SEARCH_ARCHITECTURE.md`, then measure Recall@5/10, MRR, NDCG@10, false positives and latency on representative low-end Android hardware.
