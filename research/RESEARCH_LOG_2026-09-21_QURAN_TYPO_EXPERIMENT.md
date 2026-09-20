# Research Record — Conservative Quran Typo Retrieval — 2026-09-21

Purpose: evaluate typo tolerance without weakening the existing Quran evidence boundary or creating a second normalization owner.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---|---|---|
| fact | Unicode encodes Arabic Yeh, Alef Maksura, Farsi Yeh, Yeh Barree, Heh Goal and Heh Doachashmee as distinct characters with language-specific usage. | https://www.unicode.org/Public/18.0.0/charts/nameslist/0600/ | 2026-09-21 | High | Do not casually add new character folds merely because glyphs look related. Reuse the already-reviewed `arabic-query-variant-v1` contract for this experiment. |
| fact | Arabic spelling-correction literature commonly generates edit-distance candidates and then uses contextual or language-model evidence to rank/correct them. | https://arxiv.org/abs/2108.01141 | 2026-09-21 | Medium-High | Raw edit distance is candidate evidence, not enough evidence for an authoritative match. Keep the first experiment narrow and approximate. |
| fact | Work on spelling correction for short search strings reports that human-like typo generation matters more than arbitrary noise. | https://arxiv.org/abs/2105.05977 | 2026-09-21 | Medium-High | Expand the golden set with realistic user typo patterns before runtime promotion rather than trusting synthetic nonsense negatives. |
| fact | SQLite FTS5 includes a trigram tokenizer for substring retrieval. | https://www.sqlite.org/fts5.html | 2026-09-21 | High | FTS5 remains a future measured candidate; this experiment does not justify adding it. |
| fact | Android recommends Macrobenchmark for repeated, device-level measurement of critical app journeys and runtime performance. | https://developer.android.com/topic/performance/benchmarking/macrobenchmark-overview | 2026-09-21 | High | Host Python timing cannot justify Android runtime promotion. Measure the final Kotlin/SQLite implementation on representative low-end hardware. |
| inference | Because the reader already owns strict and constrained-variant retrieval, a typo experiment should call that owner first and add exactly one new fallback after abstention. | repository + research synthesis | 2026-09-21 | High | Prevents duplicated normalization rules and makes any measured gain attributable to the fuzzy lane itself. |

## Decision

Keep the experiment local, deterministic and evaluation-only. Reuse `reader_search` and `normalize_search_constrained_variant`; do not maintain an experiment-specific keyboard/orthography table.

The candidate fuzzy rule is intentionally narrow:

- current reader search gets first refusal;
- at least two query tokens are required;
- candidate tokens must be contiguous;
- at most one Levenshtein edit is allowed across the entire query;
- single-word fuzzy search abstains;
- transposition is out of scope for this version;
- a benchmark pass does not authorize Android promotion.

## Promotion evidence still missing

The current golden set is small and contains only limited no-answer examples. Before runtime use, add realistic near-miss negatives, ambiguity cases, short-token adversarial cases and user-derived typo patterns; then measure the actual Kotlin implementation with Android Macrobenchmark on representative low-end hardware.
