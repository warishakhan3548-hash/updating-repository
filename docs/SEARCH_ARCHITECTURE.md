# Search Architecture

Search is deterministic-first, local and measured.

Keep original source text immutable and create independent search lanes: exact source Arabic, canonical Unicode, diacritic-free, constrained orthographic variants, South-Asian keyboard variants, FTS token lane, trigram/fuzzy lane and morphology/root-assisted lane. Aggressive normalization never replaces original text and contributes lower confidence.

Index Hadith matn and isnad separately. Matn-oriented queries must not be promoted merely because common narrator-chain vocabulary matched.

Candidate generation and re-ranking are separate. Signals may include exact phrase, FTS5/BM25, trigram similarity, token coverage, proximity and morphology agreement. Multi-query bundles may use Reciprocal Rank Fusion and query-consensus features.

Search may return **no reliable match**. Approximate results must be labelled approximate.

Golden-set metrics: Recall@5, Recall@10, MRR, NDCG@10, false-positive rate, zero-result rate, p50 and p95 latency. Include exact, no-harakat, typo, partial phrase, keyboard variants, concept queries, AI query bundles and no-answer cases.
