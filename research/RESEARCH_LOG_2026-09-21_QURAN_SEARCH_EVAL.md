# Research Record — Quran Search Golden Evaluation — 2026-09-21

This record covers the next step after the strict local Quran-search baseline. It changes no Evidence Plane bytes, adds no new external dataset, and does not promote a fuzzy retrieval lane.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---:|---|---|
| fact | SQLite FTS5 supports phrase queries, prefix indexes, BM25 ranking and a trigram tokenizer for substring-style retrieval. | https://www.sqlite.org/fts5.html | 2026-09-21 | High | FTS5 remains a serious candidate, but should be introduced only after measured comparison with the strict baseline. |
| fact | Android framework SQLite versions vary by API level and may also vary by device manufacturer. | https://developer.android.com/reference/android/database/sqlite/package-summary | 2026-09-21 | High | Do not assume one platform-FTS behavior across supported devices. |
| fact | AndroidX documents that FTS5 availability depends on the database driver; BundledSQLiteDriver supports FTS5. | https://developer.android.com/reference/androidx/room3/Fts5 | 2026-09-21 | High | If future evaluation proves FTS5 materially better, a bundled driver is the reproducible path to assess before changing runtime architecture. |
| fact | Unicode NFC provides canonical composition so canonically equivalent strings can compare consistently. | https://www.unicode.org/faq/normalization.html | 2026-09-21 | High | Keep the existing NFC query lane and never render it as Quran evidence. |
| fact | Quran Foundation exposes distinct quick/advanced search modes and an explicit exact-match option. | https://api-docs.quran.foundation/docs/search_apis_versioned/1.0.0/search-controller-search/ | 2026-09-21 | High | Mature Quran search benefits from separating precise lookup from broader discovery; our offline engine should measure those behaviors instead of collapsing them into one opaque score. |
| finding | The repository already has a strict, version-locked Android Quran search over quran-core 1.1.0, but no executable golden-set benchmark. | repository audit | 2026-09-21 | High | The next improvement is evaluation infrastructure, not another search engine. |
| inference | A versioned golden set tied to canonical Ayah IDs can safely expose current weaknesses (typos, orthographic and keyboard variants) without weakening abstention or source rendering. | source + repository synthesis | 2026-09-21 | High | Add measured regression coverage now; require future fuzzy/FTS lanes to beat this baseline on labelled cases before promotion. |

## Decision

Create one project-owned evaluation layer:

- `evaluation/quran_search_golden_v1.json` binds to `quran-core 1.1.0` and `arabic-search-v1`;
- exact, diacritic-free and partial-phrase cases derive query text at evaluation time from the verified runtime pack, avoiding a second copied Quran text fixture;
- typo, orthographic and South-Asian/Persian keyboard variants are explicit user-query simulations and are not represented as Quran source text;
- negative cases measure false positives and preserve abstention;
- `tools/quran_search_eval.py` mirrors the current strict SQL ranking only for measurement and emits Recall@5, Recall@10, MRR, NDCG@10, negative false-positive rate, zero-result rate and host-side latency;
- CI enforces only the current strict-search floor: exact/no-harakat/partial retrieval must not regress and deliberately no-answer cases must remain false-positive free.

The harness does **not** require typo/orthographic/keyboard cases to pass yet. Those failures are useful baseline evidence for future retrieval experiments.

## Performance boundary

The evaluator records host-side SQLite timings so regressions can be spotted during development. Those numbers are not a low-end Android performance claim. Device p50/p95 remains a separate measured milestone.
