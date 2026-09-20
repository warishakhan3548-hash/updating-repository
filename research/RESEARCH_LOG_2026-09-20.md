# Research Log — 2026-09-20

Facts were checked against primary/official sources where available. Marketing claims are treated as product descriptions, not scientific proof.

| Claim | Primary/official source | Confidence | Product implication |
|---|---|---:|---|
| Tanzil Quran text lists release v1.1 (2021-02-12); its text terms permit verbatim copy/distribution with attribution/source link and prohibit changes. | https://tanzil.net/download/ and https://tanzil.net/docs/Text_License | high | Strong Quran evidence candidate; exact selected artifact still must be captured and hashed. |
| Quranic Arabic Corpus download identifies morphology v0.4 and states GNU GPL plus explicit verbatim/no-change and attribution conditions. | https://corpus.quran.com/download/ | high | Strong morphology candidate; exact official bytes remain a gate. |
| Quran Foundation developer terms updated 2026-09-14 restrict redistribution and generally storage beyond one week except documented sync content. | https://api-docs.quran.com/legal/developer-terms/ | high | Optional online integration only; not the critical permanent mirror. |
| QUL says resources are intended to be downloaded/packaged, while also identifying external resource origins. | https://qul.tarteel.ai/resources | high | Verify each resource's provenance/licence individually; no blanket approval. |
| HadeethEnc permits re-publication under no-modification, attribution, versioning and update conditions. | https://hadeethenc.com/en | high | Hadith candidate; collection/edition/numbering provenance still needs production review. |
| Sunnah.com exposes an API and says an offline dump is not yet available. | https://sunnah.com/developers | high | Research/comparison candidate, not a durable offline foundation today. |
| SQLite FTS5 includes unicode61/trigram tokenizers and BM25 ranking. | https://sqlite.org/fts5.html | high | Strong boring baseline for measured multi-lane local retrieval. |
| FSRS-6 models Difficulty, Stability and Retrievability and is actively versioned. | https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm | medium-high | Preserve events and wrap the scheduler so algorithm versions remain replaceable. |
| Android recommends at least 48dp touch targets; WCAG 2.2 AA specifies 24x24 CSS px minimum with exceptions. | https://developer.android.com/guide/topics/ui/accessibility/views/apps-views and https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html | high | Use 48dp Android controls and expanded semantic hit regions for inline words. |
| TUF publishes version/hash/signature/rollback-oriented update specifications. | https://theupdateframework.io/spec/ | high | Use its threat-model principles for content pack activation. |
| SPDX maintains machine-readable licence identifiers and canonical licence texts. | https://spdx.org/licenses/ | high | Prefer SPDX IDs when source terms match exactly; preserve custom terms when they do not. |
| Quran.com exposes focused study/word-detail flows in addition to reading. | https://quran.com/en/product-updates/new-study-mode-on-quran-com | high | In-context depth is valuable; our first tap should stay lighter and reading-anchored. |
| Tarteel emphasizes recitation follow-along, voice search, mistake detection, memorization planning and active-recall testing. | https://tarteel.ai/ and https://support.tarteel.ai/en/collections/15105266-tarteel-features | high | Do not clone its memorization suite; borrow the principle that active recall is distinct from passive reading. |
| Readlang's official flow is click-to-translate while reading, then optional saved-word flashcards/spaced repetition. | https://readlang.com/ and https://readlang.com/features | high | Supports the north-star pattern: comprehension assistance should not eject the user from reading. |
| Quran Progress describes frequency-first Quran vocabulary plus spaced repetition. | https://www.quranprogress.com/en/ | medium | Useful comparison; independently reproduce corpus coverage before accepting numerical coverage claims. |

## First-principles synthesis

The main opportunity is not another feature dashboard. It is an invisible comprehension layer that learns how much explanation a person still needs and lets natural Quran encounters substitute for unnecessary drills.

Hadith research needs a different trust posture: multi-lane fuzzy retrieval with explicit abstention, edition-aware citations and attributed grade assertions. AI query expansion belongs outside the Evidence Plane.

## Open research gates

- exact licence snapshots and exact bytes for the chosen Tanzil text configuration;
- exact QAC v0.4 bytes and field-level importer verification;
- per-resource QUL licences;
- authoritative redistributable Hadith datasets with edition-level numbering provenance;
- full HadeethEnc edition/collection mapping;
- fonts, audio and word/ayah timing sources with explicit redistribution rights.
