# Search Architecture

Search is deterministic-first, local and measured.

Keep original source text immutable and create independent search lanes: exact source Arabic, canonical Unicode, diacritic-free, constrained orthographic variants, South-Asian keyboard variants, FTS token lane, trigram/fuzzy lane and morphology/root-assisted lane. Aggressive normalization never replaces original text and contributes lower confidence.

Index Hadith matn and isnad separately. Matn-oriented queries must not be promoted merely because common narrator-chain vocabulary matched.

Candidate generation and re-ranking are separate. Signals may include exact phrase, FTS5/BM25, trigram similarity, token coverage, proximity and morphology agreement. Multi-query bundles may use Reciprocal Rank Fusion and query-consensus features.

Search may return **no reliable match**. Approximate results must be labelled approximate.

Golden-set metrics: Recall@5, Recall@10, MRR, NDCG@10, false-positive rate, zero-result rate, p50 and p95 latency. Include exact, no-harakat, typo, partial phrase, keyboard variants, concept queries, AI query bundles and no-answer cases.

## Implemented Quran baseline — 2026-09-20

The Android reader keeps a deliberately strict offline Quran lane over the existing `quran-core 1.1.0` derived fields. Pack-bound query normalization is version-locked to `arabic-search-v1`; a pack/runtime mismatch fails closed. Strict retrieval uses literal SQLite `instr` containment over NFC and diacritic-free lanes, with exact/prefix matches ordered before broader containment. Results expose canonical ayah coordinates and render only `original_text`.

When and only when strict retrieval returns no rows, the reader may run the query-only `arabic-query-variant-v1` fallback. It performs a small fixed set of Arabic orthographic and South-Asian keyboard substitutions (for example alef-wasla/hamza-alef → alef, Farsi yeh → Arabic yeh, keheh → kaf, heh-goal → heh). It is deterministic, does not alter the content pack, does not use NFKC, and never becomes display text. Every result from this fallback is labelled **Approximate spelling match**.

This baseline still does **not** claim edit-distance typo tolerance, conceptual, root, morphology or AI-expanded retrieval. Those remain evaluation-gated behind the labelled golden set. Empty retrieval is allowed to abstain with **No reliable match found**.

## Executable golden set — 2026-09-21

The first labelled Quran retrieval benchmark is now executable at `evaluation/quran_search_golden_v1.json` through `tools/quran_search_eval.py`. It is bound to `quran-core 1.1.0` and `arabic-search-v1`, and it measures the reader contract rather than introducing a second production search implementation.

Exact-source, diacritic-free and partial-phrase queries are derived at evaluation time from the verified runtime pack using canonical Ayah IDs. Explicit typo, orthographic and keyboard-variant strings are treated only as simulated user queries, never as Quran display evidence. Deliberate no-answer cases measure false positives and preserve abstention.

CI enforces Recall@5 = 1.0 for exact-source, diacritic-free and partial-phrase categories and for the constrained orthographic and South-Asian keyboard categories, while retaining a zero false-positive rate for labelled no-answer cases. The query-variant fallback is evaluated as a distinct `approximate_spelling` match mode. Edit-distance typo cases remain measured but are not promoted as a supported runtime capability.

The evaluator emits Recall@5, Recall@10, MRR, NDCG@10, negative false-positive rate and zero-result rate. Host SQLite p50/p95 are diagnostic only; low-end Android latency remains a separate device measurement.

## Conservative typo experiment — 2026-09-21

`quran-conservative-fuzzy-v1` is evaluation-only. It reuses the existing reader's complete strict → `arabic-query-variant-v1` ladder first; it does **not** define a second orthographic/keyboard normalization policy. Only after that reader contract returns no rows may the experiment attempt one-edit matching.

The fuzzy fallback requires a multi-word query and a contiguous candidate window. Each token must be identical or at Levenshtein distance one, and the **entire query may consume at most one edit total**. Single-word fuzzy guesses abstain. Adjacent transposition is not included in this first experiment.

The experiment must recover the labelled typo cases without displacing any existing strict/variant match and without producing a labelled no-answer false positive. Passing the small host golden set is necessary but not sufficient for Android promotion: the negative/ambiguity corpus must be expanded and real low-end-device latency must be measured first. Android's Macrobenchmark tooling is the preferred device measurement path. Source-faithful `original_text` remains the only renderable Quran text.
