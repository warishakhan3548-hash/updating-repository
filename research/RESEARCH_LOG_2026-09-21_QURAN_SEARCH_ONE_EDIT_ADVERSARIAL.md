# Research Record — Adversarial Quran one-edit candidate — 2026-09-21

Purpose: strengthen the existing evaluation-only Quran typo hypothesis without changing Android runtime search, Quran source bytes, canonical content, or the active `quran-search-golden-v2` contract.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---:|---|---|
| fact | Unicode assigns distinct code points to Arabic-script letters used across Arabic, Persian and Urdu, including Farsi Yeh and Heh Goal. | https://www.unicode.org/Public/18.0.0/charts/nameslist/0600/ | 2026-09-21 | High | Keep the existing reviewed query-variant normalizer; edit-distance logic must not invent new destructive character folds. |
| fact | SQLite FTS5 offers a trigram tokenizer for substring retrieval, but it is a broader retrieval mechanism than the current constrained one-edit hypothesis. | https://www.sqlite.org/fts5.html | 2026-09-21 | High | Do not add an FTS/trigram dependency merely because it exists; measure the narrow candidate first. |
| fact | Android recommends Macrobenchmark for end-user interactions, and official guidance discourages emulator performance numbers as representative of user experience. | https://developer.android.com/topic/performance/benchmarking/macrobenchmark-overview | 2026-09-21 | High | Host Python timing cannot authorize Android promotion. Equivalent Kotlin behavior must be measured on representative physical hardware. |
| finding | The previous one-edit experiment recovered the remaining labelled typo but its active-v2 benchmark had only two labelled no-answer cases. | repository benchmark audit | 2026-09-21 | High | Create a separate candidate benchmark with explicit short-query, multi-error, ambiguity and transposition cases; do not rewrite historical v2. |
| finding | The first adversarial candidate CI run kept supported exact/diacritic/partial/typo/orthographic/keyboard Recall@5 at 1.0 and labelled no-answer false-positive rate at 0.0. | GitHub Actions run 35533035272 | 2026-09-21 | High | The stricter hypothesis survives this expanded gate, but remains experimental. |
| finding | The deliberately unsupported transposition case has Recall@5 = 0.0, producing aggregate candidate Recall@5/MRR = 0.9444 rather than a universal typo-success claim. | GitHub Actions run 35533035272 | 2026-09-21 | High | Preserve explicit abstention instead of silently broadening edit semantics. |
| finding | Host full-corpus timing on that runner was p50 26.897 ms and p95 70.38 ms. | GitHub Actions run 35533035272 | 2026-09-21 | Medium | Diagnostic only; do not treat hosted-runner timing as low-end Android performance. |

## Candidate policy

The candidate runs only after strict search and `arabic-query-variant-v1` both abstain.

It now requires:

- at least three query tokens;
- a contiguous candidate token window of the same width;
- exactly one insertion, deletion or substitution across the full phrase;
- no adjacent-transposition special case;
- a unique candidate ayah; ambiguous fuzzy matches abstain;
- original Quran/source text remains untouched and is never replaced by normalized strings.

The candidate benchmark explicitly includes:

- insertion, substitution and deletion recovery;
- short fuzzy phrases that must abstain;
- a two-edit phrase that must abstain;
- a repeated divine phrase whose one-edit candidate maps to multiple ayahs and must abstain;
- an adjacent-transposition case that remains unsupported and must abstain.

## Architecture decision

Do **not** promote `quran-one-edit-fallback-v1` to Android in this change.

The active runtime remains:

strict literal search → constrained spelling variants → abstention.

Promotion still requires broader user-derived typo evidence, an equivalent Kotlin implementation, and representative low-end physical-device measurement. If a future implementation materially changes supported behavior, create a new versioned benchmark/engine contract rather than silently mutating this candidate.
