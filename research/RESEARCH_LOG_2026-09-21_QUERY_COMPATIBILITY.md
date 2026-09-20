# Research Log — Quran Query Compatibility — 2026-09-21

## Decision

Add a deliberately small, versioned spelling-compatibility fallback after the existing strict Quran search lane. Do not add typo/edit-distance search in this change, and do not alter any Evidence Plane text or content-pack source field.

## Verified facts

| Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---:|---|---|
| Unicode 18.0 identifies U+0671 as ARABIC LETTER ALEF WASLA and marks it as Quranic Arabic. | https://www.unicode.org/Public/18.0.0/charts/nameslist/0600/ | 2026-09-21 | high | A query-side/source-side compatibility fold may bridge bare alef and wasla spelling without rewriting display text. |
| Unicode 18.0 identifies U+06CC as ARABIC LETTER FARSI YEH and notes Arabic/Persian/Urdu/Kashmiri use; it cross-references Arabic Yeh U+064A. | https://www.unicode.org/Public/18.0.0/charts/nameslist/0600/ | 2026-09-21 | high | A narrowly-scoped Farsi-Yeh→Arabic-Yeh search fold is justified for keyboard compatibility. |
| Unicode 18.0 identifies U+06C1 as ARABIC LETTER HEH GOAL used in Urdu. | https://www.unicode.org/Public/18.0.0/charts/nameslist/0600/ | 2026-09-21 | high | A narrowly-scoped Heh-Goal→Arabic-Heh search fold is justified for Urdu keyboards. |
| SQLite documents deterministic built-in `instr(X,Y)` substring matching and `replace(X,Y,Z)` substitution. | https://sqlite.org/lang_corefunc.html | 2026-09-21 | high | The fallback can remain local and dependency-free over the existing 6,236-row Quran table. |
| QUL still requires resource-specific licensing review for production/commercial use. | https://qul.tarteel.ai/docs/faq | 2026-09-21 | high | No QUL morphology bytes are promoted by this search change. |
| QuranEnc currently states republication conditions including no modification, source/version attribution and staying updated to the latest issued version. | https://quranenc.com/en/home | 2026-09-21 | medium-high | Current QuranEnc legal/freshness gates remain separate; this search change must not depend on QuranEnc. |

## Architectural inference

The safest immediate retrieval gain is a fallback that activates only when strict search returns zero results. That preserves exact/no-harakat behavior and abstention as the first authority while recovering selected orthographic and South-Asian keyboard variants.

The compatibility mapping is intentionally not a general Arabic normalizer. Each extra fold can collapse distinct spellings and therefore must earn inclusion through labelled search cases and false-positive review.

## Implementation hypothesis

`arabic-query-compat-v1` folds only:

- `ٱ أ إ آ` → `ا`
- `ی` → `ي`
- `ہ` → `ه`

The host evaluator mirrors the Android SQL. `quran-search-golden-v2` requires Recall@5 = 1.0 for exact, diacritic-free, partial phrase, orthographic-variant and keyboard-variant categories while preserving a zero labelled negative false-positive rate.

Compatibility results are explicitly labelled **Approximate spelling match** and render only the original Quran source text.

## Out of scope

- edit-distance typo tolerance;
- roots/morphology;
- semantic/concept search;
- AI query expansion;
- any new Quran/Hadith evidence source;
- low-end Android performance claims.

Those remain separate measured milestones.
