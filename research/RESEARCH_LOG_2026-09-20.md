# Research Log — 2026-09-20

Facts were checked against primary/official sources where available. Marketing claims are treated as product descriptions, not scientific proof. Architectural inference and experimental hypotheses are labelled separately.

| Type | Claim | Primary/official source | Confidence | Product implication |
|---|---|---|---:|---|
| fact | Tanzil Quran text lists release v1.1 (2021-02-12); its text terms permit verbatim copy/distribution with attribution/source link and prohibit changes. The selected Uthmani v1.1 artifact is now preserved in this project's Source Vault and promoted only through checksum/licence/provenance gates. | https://tanzil.net/download/ and https://tanzil.net/docs/Text_License | high | Approved Quran evidence foundation for the pinned configuration; never mutate its source/display bytes. |
| fact | Quranic Arabic Corpus download identifies morphology v0.4 and states GNU licence plus explicit verbatim/no-change and attribution conditions, while its official FAQ also describes the data as non-commercial research material. | https://corpus.quran.com/download/ and https://corpus.quran.com/faq.jsp | high | Keep QAC out of production until the licensing ambiguity is resolved or explicit permission is obtained. |
| fact | Quran Foundation developer terms updated 2026-09-14 restrict redistribution and generally storage beyond one week except documented sync content/explicit permission. | https://api-docs.quran.com/legal/developer-terms/ | high | Optional online integration only; not the critical permanent mirror. |
| fact | QuranEnc exposes versioned downloadable translations and permits re-publication subject to no-modification, source/publisher attribution, version and transcript conditions. | https://quranenc.com/en/home | high | Evaluate and preserve each exact translation/version independently. |
| fact | QUL says resources are intended to be downloaded/packaged, while also identifying external resource origins. | https://qul.tarteel.ai/resources | high | Verify each resource's provenance/licence individually; no blanket approval. |
| fact | HadeethEnc permits re-publication under no-modification, attribution, versioning and update conditions. | https://hadeethenc.com/en | high | Hadith candidate; collection/edition/numbering provenance still needs production review. |
| fact | Sunnah.com exposes an API and says an offline dump is not yet available. | https://sunnah.com/developers | high | Research/comparison candidate, not a durable offline foundation today. |
| fact | SQLite FTS5 includes unicode61/trigram tokenizers and BM25 ranking. | https://sqlite.org/fts5.html | high | Strong boring baseline for measured multi-lane local retrieval. |
| fact | SQLite's documented database header stores both a file change counter and the `SQLITE_VERSION_NUMBER` of the library that most recently modified the database. | https://sqlite.org/fileformat.html | high | Treat a release SQLite SHA-256 as identity for those exact built bytes, not as the sole semantic proof across toolchain versions; independently verify source-to-pack content fidelity. |
| fact | Unicode UAX #15 defines canonical normalization. | https://www.unicode.org/reports/tr15/ | high | Normalize only derived search lanes; original Arabic remains immutable display evidence. |
| fact | Current FSRS documentation still centers the D/S/R model and FSRS-6, while the ecosystem already contains newer-version implementations/benchmark references. | https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm and https://github.com/open-spaced-repetition/awesome-fsrs | medium-high | Preserve raw review events and keep FSRS behind an adapter; never make one scheduler version part of the permanent user-data schema. |
| fact | Android recommends at least 48dp touch targets; WCAG 2.2 AA specifies 24x24 CSS px minimum with exceptions. | https://developer.android.com/guide/topics/ui/accessibility/views/apps-views and https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html | high | Use 48dp Android controls and expanded semantic hit regions for inline words. |
| fact | TUF publishes version/hash/signature/rollback-oriented update specifications. | https://theupdateframework.io/spec/ | high | Use its threat-model principles for content pack activation. |
| fact | SPDX maintains machine-readable licence identifiers and canonical licence texts. | https://spdx.org/licenses/ | high | Prefer SPDX IDs when source terms match exactly; preserve custom terms when they do not. |
| fact | Quran.com added Study Mode and a related-Hadith tab in 2026, showing that users value contextual depth without abandoning the reading flow. | https://quran.com/product-updates | high | Keep our first tap lighter than a full study screen; when Hadith is shown, preserve edition-aware citations and explicit evidence boundaries. |
| fact | Quran.com exposes focused study/word-detail flows in addition to reading. | https://quran.com/en/product-updates/new-study-mode-on-quran-com | high | In-context depth is valuable; our first tap should stay lighter and reading-anchored. |
| fact | Tarteel emphasizes recitation follow-along, voice search, mistake detection and active recall; its support material also acknowledges that mistake detection can flag false positives. | https://tarteel.ai/ and https://support.tarteel.ai/ | high | Machine detections need confidence plus confirm/reject history; they cannot become unquestionable learning truth. |
| fact | Readlang uses click-to-translate reading plus saved contextual words/review; LingQ similarly combines contextual reading with tracked vocabulary/SRS. | https://readlang.com/features and https://www.lingq.com/en/learn-arabic-online/ | high | Supports reader-driven low-friction learning rather than a separate drill-first product. |
| fact | Quran Progress describes frequency-first Quran vocabulary plus spaced repetition. | https://www.quranprogress.com/en/ | medium | Useful comparison; independently reproduce corpus coverage before accepting numerical coverage claims. |
| inference | The best default comprehension assist is an anchored micro-gloss rather than navigation to a separate study screen. | synthesis of reader products + product north star | medium | Prototype and user-test before declaring final UX. |
| hypothesis | Natural re-exposure in the user's reading path can sometimes substitute for forced rare-word review. | cognitive/product hypothesis | medium | Evaluate against retention and interruption metrics. |

## First-principles synthesis

The main opportunity is not another feature dashboard. It is an invisible comprehension layer that learns how much explanation a person still needs and lets natural Quran encounters substitute for unnecessary drills.

Hadith research needs a different trust posture: multi-lane fuzzy retrieval with explicit abstention, edition-aware citations and attributed grade assertions. AI query expansion belongs outside the Evidence Plane.

## Open research gates

- exact QAC v0.4 bytes and field-level importer verification;
- per-resource QUL licences;
- authoritative redistributable Hadith datasets with edition-level numbering provenance;
- full HadeethEnc edition/collection mapping;
- exact QuranEnc translation/version selection where translations are used;
- fonts, audio and word/ayah timing sources with explicit redistribution rights.

## Saturation conclusion

The research now converges on four durable choices: immutable source/display data, contextual reader-first assistance, local event-preserving learning, and deterministic multi-lane retrieval with explicit uncertainty. Further research should answer concrete implementation/evaluation questions rather than accumulate features.
