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

## Executable golden sets — 2026-09-21

Golden benchmarks are append-only/versioned contracts rather than mutable filenames. `evaluation/quran_search_golden_v1.json` preserves the original strict-search baseline exactly as it existed before the spelling fallback was promoted. It remains historical evidence and is not silently reinterpreted under newer retrieval behavior.

The active benchmark is `evaluation/quran_search_golden_v2.json` through `tools/quran_search_eval.py`. It is bound to `quran-core 1.1.0`, pack search normalization `arabic-search-v1`, and runtime query-variant contract `arabic-query-variant-v1`. A missing or mismatched runtime binding fails evaluation before metrics are accepted.

Exact-source, diacritic-free and partial-phrase queries are derived at evaluation time from the verified runtime pack using canonical Ayah IDs. Explicit typo, orthographic and keyboard-variant strings are treated only as simulated user queries, never as Quran display evidence. Deliberate no-answer cases measure false positives and preserve abstention.

CI enforces Recall@5 = 1.0 for exact-source, diacritic-free, partial-phrase, constrained orthographic and South-Asian keyboard categories, while retaining a zero false-positive rate for labelled no-answer cases. The fallback is evaluated as a distinct `approximate_spelling` match mode. Edit-distance typo cases remain measured but are not promoted as a supported capability. Any future FTS5, trigram, edit-distance, morphology or AI-expanded lane must create a new benchmark version when its supported contract or relevance judgments change and must demonstrate a measured gain without degrading exact retrieval, abstention or source-faithful rendering.

The evaluator emits Recall@5, Recall@10, MRR, NDCG@10, negative false-positive rate and zero-result rate. Host SQLite p50/p95 are diagnostic only; low-end Android latency remains a separate device measurement.


## One-edit typo experiment — 2026-09-21

A follow-on experiment evaluates a narrower typo fallback **after both the strict lane and `arabic-query-variant-v1` have abstained**. It remains host-side evaluation code only; Android runtime behavior is unchanged.

The original experiment demonstrated useful recovery but its active-v2 benchmark had too little adversarial negative coverage for runtime promotion. The candidate is now isolated in `evaluation/quran_search_one_edit_candidate_v1.json` so the active `quran-search-golden-v2` runtime contract stays immutable.

The candidate requires at least **three query tokens**, a contiguous same-width token window, and exactly **one insertion, deletion or substitution total** across the phrase. It abstains if the fuzzy phrase identifies more than one ayah. Single/two-token fuzzy phrases, two-error phrases, ambiguous repeated phrases and adjacent transpositions are pinned as abstentions. These constraints deliberately trade recall for lower false-positive risk around sacred text.

GitHub CI on the first adversarial candidate run preserved Recall@5 = 1.0 for the supported exact-source, diacritic-free, partial-phrase, typo, orthographic-variant and keyboard-variant categories and kept labelled no-answer false-positive rate at 0.0. The deliberately unsupported transposition case remains at Recall@5 = 0.0, so aggregate candidate Recall@5/MRR are 0.9444 rather than being misreported as universal typo support. Host full-corpus timing on that runner was p50 26.897 ms and p95 70.38 ms; these figures are diagnostic only.

Runtime promotion is still blocked. Equivalent Kotlin behavior, broader user-derived typo data and representative low-end **physical-device** measurement remain required before Android adoption. The Android baseline therefore continues to show only strict and constrained spelling matches and may still return **No reliable match found** for edit-distance typos.
