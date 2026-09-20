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

The first labelled Quran retrieval benchmark is now executable at `evaluation/quran_search_golden_v1.json` through `tools/quran_search_eval.py`. It is bound to `quran-core 1.1.0` and `arabic-search-v1`, and it measures the existing strict engine rather than introducing a second production search implementation.

Exact-source, diacritic-free and partial-phrase queries are derived at evaluation time from the verified runtime pack using canonical Ayah IDs. Explicit typo, orthographic and keyboard-variant strings are treated only as simulated user queries, never as Quran display evidence. Deliberate no-answer cases measure false positives and preserve abstention.

CI enforces Recall@5 = 1.0 for exact-source, diacritic-free and partial-phrase categories and now also for the constrained orthographic and South-Asian keyboard categories, while retaining a zero false-positive rate for labelled no-answer cases. The fallback is evaluated as a distinct `approximate_spelling` match mode. Edit-distance typo cases remain measured but are not promoted as a supported capability. Any future FTS5, trigram, edit-distance, morphology or AI-expanded lane must demonstrate a measured gain without degrading exact retrieval, abstention or source-faithful rendering.

The evaluator emits Recall@5, Recall@10, MRR, NDCG@10, negative false-positive rate and zero-result rate. Host SQLite p50/p95 are diagnostic only; low-end Android latency remains a separate device measurement.


## One-edit typo experiment — 2026-09-21

A follow-on experiment evaluates a narrower typo fallback **after both the strict lane and `arabic-query-variant-v1` have abstained**. It is host-side evaluation code only; Android runtime behavior is unchanged.

The fallback refuses single-word fuzzy guesses. For a multi-word query, a candidate must match a contiguous token window of the same width, each token must be identical or at edit distance one, and the whole query may consume at most **one insertion, deletion or substitution total**. This keeps the evidence threshold substantially tighter than generic fuzzy search.

Promotion requires the existing labelled golden set to retain Recall@5 = 1.0 for exact-source, diacritic-free, partial-phrase, orthographic-variant and keyboard-variant cases, raise the labelled typo category to Recall@5 = 1.0, and keep labelled no-answer false-positive rate at 0.0. Even a passing host benchmark is not sufficient for Android adoption: low-end-device latency and equivalent Kotlin behavior still require measurement and review.
