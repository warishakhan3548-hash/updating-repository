# Search Architecture

Search is deterministic-first, local and measured.

Keep original source text immutable and create independent search lanes: exact source Arabic, canonical Unicode, diacritic-free, constrained orthographic variants, South-Asian keyboard variants, FTS token lane, trigram/fuzzy lane and morphology/root-assisted lane. Aggressive normalization never replaces original text and contributes lower confidence.

Index Hadith matn and isnad separately. Matn-oriented queries must not be promoted merely because common narrator-chain vocabulary matched.

Candidate generation and re-ranking are separate. Signals may include exact phrase, FTS5/BM25, trigram similarity, token coverage, proximity and morphology agreement. Multi-query bundles may use Reciprocal Rank Fusion and query-consensus features.

Search may return **no reliable match**. Approximate results must be labelled approximate.

Golden-set metrics: Recall@5, Recall@10, MRR, NDCG@10, false-positive rate, zero-result rate, p50 and p95 latency. Include exact, no-harakat, typo, partial phrase, keyboard variants, concept queries, AI query bundles and no-answer cases.

## Implemented Quran baseline — 2026-09-20

The Android reader now has one deliberately strict offline Quran lane over the existing `quran-core 1.1.0` derived fields. Query normalization is version-locked to `arabic-search-v1`; a pack/runtime mismatch fails closed. Retrieval uses literal SQLite `instr` containment over NFC and diacritic-free lanes, with exact/prefix matches ordered before broader containment. Results expose canonical ayah coordinates and render only `original_text`.

This baseline does **not** claim fuzzy, conceptual, root, morphology, typo-tolerant or AI-expanded retrieval. Those remain evaluation-gated behind the labelled golden set. Empty retrieval is allowed to abstain with **No reliable match found**.

## Executable golden set — 2026-09-21

The first labelled Quran retrieval benchmark is now executable at `evaluation/quran_search_golden_v1.json` through `tools/quran_search_eval.py`. It is bound to `quran-core 1.1.0` and `arabic-search-v1`, and it measures the existing strict engine rather than introducing a second production search implementation.

Exact-source, diacritic-free and partial-phrase queries are derived at evaluation time from the verified runtime pack using canonical Ayah IDs. Explicit typo, orthographic and keyboard-variant strings are treated only as simulated user queries, never as Quran display evidence. Deliberate no-answer cases measure false positives and preserve abstention.

CI currently enforces the regression floor that the strict engine actually promises: Recall@5 = 1.0 for exact-source, diacritic-free and partial-phrase categories, plus a zero false-positive rate for labelled no-answer cases. Typo, orthographic and keyboard categories are measured without being required to pass. Any future FTS5, trigram, edit-distance, morphology or AI-expanded lane must demonstrate a measured gain on the labelled set without degrading exact retrieval, abstention or source-faithful rendering.

The evaluator emits Recall@5, Recall@10, MRR, NDCG@10, negative false-positive rate and zero-result rate. Host SQLite p50/p95 are diagnostic only; low-end Android latency remains a separate device measurement.


## Conservative query compatibility fallback — 2026-09-21

The strict Quran lane remains authoritative and unchanged: exact/NFC and diacritic-free containment run first against the provenance-bound `arabic-search-v1` fields. Only when that strict lane returns zero results may the reader use `arabic-query-compat-v1`, a tiny query/source spelling-compatibility fold evaluated at runtime.

Version 1 folds only:

- Quranic alef wasla `ٱ` and alef-with-hamza/madda variants `أ إ آ` to bare `ا`;
- Farsi Yeh `ی` to Arabic Yeh `ي`;
- Urdu Heh Goal `ہ` to Arabic Heh `ه`.

No stored Quran text, canonical JSONL or content-pack search field is rewritten. The compatibility lane is a retrieval aid only, uses deterministic SQLite `replace()` + `instr()`, and its results are labelled **Approximate spelling match** in the UI. Adding another fold requires a labelled golden-set case and regression review; typo/edit-distance search remains unimplemented.

`quran-search-golden-v2` promotes orthographic and South-Asian keyboard variants into the required Recall@5 floor while retaining zero labelled negative false positives. Host SQLite latency remains diagnostic only; low-end Android measurement is still required before making a device-performance claim.
