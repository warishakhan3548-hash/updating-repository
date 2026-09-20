# Research Record — Quran Search Constrained Variants — 2026-09-21

Purpose: improve common Arabic orthographic and South-Asian keyboard recall without weakening Quran source integrity, silently broadening fuzzy confidence, or introducing a new content dependency.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---:|---|---|---|
| fact | Unicode normalization distinguishes canonical normalization from compatibility normalization; compatibility normalization can erase distinctions and should not be used blindly as a search policy. | https://www.unicode.org/reports/tr15/ | 2026-09-21 | High | Keep NFC as the canonical query lane and make any broader substitutions explicit, narrow and versioned. |
| fact | SQLite FTS5 provides BM25/prefix support and a trigram tokenizer for substring-style retrieval. | https://www.sqlite.org/fts5.html | 2026-09-21 | High | FTS5 remains a future measured option; it is unnecessary for a small deterministic script-variant fallback. |
| fact | Android platform SQLite versions can vary with OS/API and device implementation, while AndroidX bundled SQLite can provide a controlled FTS5-capable engine. | https://developer.android.com/reference/android/database/sqlite/package-summary ; https://developer.android.com/reference/androidx/room3/Fts5 | 2026-09-21 | High | Do not introduce platform-FTS assumptions until benchmark gains justify the dependency/runtime change. |
| finding | The existing golden set already contains orthographic and South-Asian keyboard cases that strict NFC/diacritic-free containment intentionally does not promise. | repository audit | 2026-09-21 | High | Improve those labelled cases before adding generic fuzzy search. |
| inference | A strict-miss-only substitution lane can improve recall while preserving exact-match priority and explicit abstention. | source + repository synthesis | 2026-09-21 | High | Add `arabic-query-variant-v1`; label all fallback results approximate and keep edit-distance typos outside the supported contract. |

## Decision

Keep `arabic-search-v1` unchanged as the source-pack-bound normalization contract. Add a separate query-only `arabic-query-variant-v1` fallback with a deliberately small mapping:

- alef wasla / hamza-alef / madda-alef → plain alef;
- alef maksura → Arabic yeh;
- Farsi yeh → Arabic yeh;
- keheh → Arabic kaf;
- heh goal → Arabic heh.

Execution order is invariant:

1. run strict NFC + diacritic-free retrieval;
2. if strict returns any rows, return those rows and do not invoke the fallback;
3. if strict abstains, run the constrained variant lane;
4. label every fallback hit **Approximate spelling match**;
5. if the fallback also returns nothing, preserve **No reliable match found**.

No source, canonical, content-pack, licence, provenance or Quran display bytes change in this milestone. No FTS5, trigram, edit-distance, morphology or AI dependency is introduced.

## Evaluation gate

The existing golden benchmark remains the authority. Exact-source, diacritic-free and partial-phrase Recall@5 floors remain 1.0, labelled no-answer false-positive rate remains 0.0, and orthographic/keyboard Recall@5 are promoted to 1.0 only through the constrained fallback. Typo cases remain diagnostic rather than a supported promise.
