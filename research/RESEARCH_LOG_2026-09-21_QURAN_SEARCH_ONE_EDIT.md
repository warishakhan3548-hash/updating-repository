# Research Record — Conservative Quran typo fallback — 2026-09-21

Purpose: evaluate the remaining typo-retrieval gap without weakening Quran evidence, duplicating the existing spelling-normalization owner, or treating host benchmark success as runtime proof.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---|---|---|
| fact | Unicode encodes Arabic Yeh, Alef Maksura, Farsi Yeh, Yeh Barree, Heh Goal and Heh Doachashmee as distinct characters with language-specific usage. | https://www.unicode.org/Public/18.0.0/charts/nameslist/0600/ | 2026-09-21 | High | The typo experiment must reuse the already-reviewed `arabic-query-variant-v1` normalization instead of inventing additional folds. |
| fact | Arabic spelling-correction research uses edit-distance candidates together with contextual/language-model evidence rather than treating raw edit distance as sufficient proof of the intended word. | https://arxiv.org/abs/2108.01141 | 2026-09-21 | Medium-High | One edit is only candidate evidence. Keep results approximate and the first deterministic experiment deliberately narrow. |
| fact | Research on short search-query correction reports that realistic human typo patterns matter and evaluates learned correction against actual query-like errors. | https://arxiv.org/abs/2105.05977 | 2026-09-21 | Medium-High | Expand the golden set with realistic user-derived typo/near-miss cases before runtime promotion. |
| fact | SQLite FTS5 provides a trigram tokenizer for substring retrieval. | https://www.sqlite.org/fts5.html | 2026-09-21 | High | A heavier trigram/FTS lane remains evaluation-gated; this experiment does not justify adding it. |
| fact | Android recommends Macrobenchmark for repeated device-level measurement of user-visible performance; emulator numbers are not representative of a physical device. | https://developer.android.com/topic/performance/benchmarking/macrobenchmark-overview | 2026-09-21 | High | Host Python timing cannot authorize Android promotion. Measure the eventual Kotlin/SQLite implementation on representative low-end physical hardware. |
| finding | After the measured spelling-variant fallback landed on main, one golden case labelled `typo` is already recovered as `approximate_spelling`; only the residual typo miss needs the one-edit lane. | repository CI audit | 2026-09-21 | High | Require incremental one-edit recovery, not takeover of all typo-labelled cases. |

## Decision

The experiment starts from the current reader contract: strict literal search → `arabic-query-variant-v1` → abstention. Only after both existing lanes return no rows may `quran-one-edit-fallback-v1` run.

The candidate rule is intentionally narrow:

- require at least two query tokens;
- compare only contiguous, same-width token windows;
- allow at most one insertion, deletion or substitution across the entire query;
- do not treat adjacent transposition as one edit in this version;
- preserve single-word fuzzy abstention;
- preserve original Quran/source text and all Evidence Plane bytes;
- require at least one residual typo recovery, while forbidding the one-edit lane from displacing non-typo baseline categories.

## Evidence still missing for runtime promotion

The current golden set is small and has only limited no-answer coverage. Before Android adoption, add realistic near-miss negatives, ambiguity cases, short-token adversarial cases, transposition cases and user-derived typo patterns. Then implement the same logic in Kotlin and measure it on representative low-end physical hardware with Android benchmarking tools.

A host-side pass is evidence that the hypothesis deserves further testing. It is not a claim that the runtime search is safe, fast, or production-ready.
