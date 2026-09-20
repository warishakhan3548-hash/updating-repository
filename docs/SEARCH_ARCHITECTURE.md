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


## Conservative fuzzy experiment — 2026-09-21

The next retrieval experiment remains evaluation-only and adds no new evidence or runtime dependency. `quran-conservative-fuzzy-v1` derives a search-only variant lane from the existing diacritic-free field by mapping a deliberately small set of common Quranic/keyboard forms (including alef-wasla/hamzated alef and Persian/South-Asian yeh/kaf/heh forms) to ordinary Arabic search characters.

If no variant-normalized substring is found, the experiment permits a fuzzy fallback only for multi-word queries. Candidate words must form one contiguous window, every token must be identical or one edit away, and the **entire query may consume at most one edit total**. Single-word fuzzy queries abstain. This is intentionally much narrower than generic edit-distance search.

The experiment is CI-gated against the existing labelled golden set. It is not promoted into Android merely because the host benchmark passes: exact/no-harakat/partial behavior and labelled no-answer abstention must remain intact, and low-end Android latency must be measured before runtime adoption. Source-faithful `original_text` remains the only renderable Quran text.
