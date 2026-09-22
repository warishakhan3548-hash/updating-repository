# Architecture audit — 22 September 2026

The supplied 35-page Quran Comprehension & Evidence OS architecture is **not complete**.
This repository now contains a recovered native application and a tested deterministic Quran
foundation. The table separates implemented code from data, integration and validation still needed.
An empty table, an interface or a scoring function does not count as a finished feature.

| Area | Implemented now | Remaining |
| --- | --- | --- |
| Source Vault | Pinned raw Quran/gloss snapshots, source lock, licenses, hash checks, deterministic builder, validation report | Reviewer-approved contextual gloss/sense packs; commercial content clearance |
| Quran content | 114 surahs, 6,236 coordinates, unchanged Tanzil text, 77,881 source word ranges; 77,766 aligned gloss ranges | Nine mismatched ayah mappings remain withheld; no guessed corrections |
| Native reader | Java Android 8+ shell, Amiri, teal/blue/gold glass surfaces, Aaj/Quran/Naksha, word meaning ribbon above/below the tapped line, highlight without reflow, bookmarks, notes, font size, contrast, quiet controls; Unicode viewport anchor across redraw/restart | Real-device visual/accessibility/large-font/rotation tests; authentic IndoPak renderer; automatic control fading |
| Immutable/mutable separation | Quran opens read-only after checksum verification; learning lives in a separate SQLite database | Signed pack updates, rollback and key rotation; encrypted backup |
| Durable identity | Quran coordinates; prefatory basmala words; word IDs; exact-range phrase IDs; directed consecutive-ayah transition IDs | Reviewed root → lexeme → contextual sense → occurrence graph; edition-aware Hadith citation identities |
| Learning ledger | Append-only events, idempotent review IDs, conflicting-ID rejection, replay, opt-in enrollment/pause, monotonic local timestamps across restart/restore | Incremental durable projections and large-history device performance; richer comprehension dimensions |
| Recall | Word meaning plus phrase/ayah memorization; independently scheduled ayah-transition practice using separately cited ending/opening excerpts; initial read/hide/recall/reveal/self-rating; versioned conservative scheduler | Calibrated FSRS adapter; audio cues; automatic diagnosis of the failed phrase; learning which cue helps later unaided recall |
| Natural retrieval | Exact saved word occurrence lookahead, one-day maximum deferral, fresh difficulty cancels deferral; optional reader recall action | Cross-context natural review requires reviewed sense mappings. Similar surfaces/glosses never transfer mastery |
| Rare-word rescue | Pure relevance/risk/scarcity scoring primitive with finite-value checks | Not wired to a measured exposure forecast or product ranking; no claim of complete rare-word rescue |
| Quran retrieval | Arabic/gloss BM25 indexes, safe/tolerant query shadows, bounded trigram-assisted spelling candidates, RRF, injective token coverage, exact negation, abstention, multi-query provenance, deterministic ties; bounded exact fragment segmentation with alternatives and unmatched spans | Curated concepts, root/lemma analysis, phonetic transliteration, optional multilingual embeddings/reranker; explicit query locks; native FTS5 adapter if justified |
| Hadith research | UI honestly says no approved pack is installed; placeholder schema only | Rights/edition-cleared corpus, matn/isnad indexes, grade assertions, narration clusters and labeled evaluation |
| AI boundary | No model supplies scripture. User-controlled query/reasoning prompts; export selected immutable evidence | AI-provider integrations are not necessary for core reading and are not installed |
| Evidence bundle | PDF/TXT/JSON/manifest code, source checksums, per-record selection/retrieval provenance and portable hash format | Android runtime PDF visual QA and document-provider lifecycle tests |
| Verify-back | Citation existence, exact supported quotes, unknown/malformed IDs and unattached quote reporting; snapshot compared to installed source | Conclusions/interpretation are deliberately not verified; unsupported quotation formats are disclosed |
| Learning portability | Local JSON backup; whole-input validation; transactional merge; no destructive overwrite on restore | Encryption; old/new schema migration fixtures; document-picker process-death testing |
| Privacy/ambient | No account, ads, analytics, network permission, accessibility service or overlay permission | Optional ambient recall, widgets, notification scheduling and consent controls have not been implemented |
| Evaluation | Dependency-free JVM regressions; whole-corpus coordinate checks; small positive/absent query regression set | Scholar/reviewer labels, larger multilingual/zero-answer evaluation, false-positive calibration and phone latency/battery profiling |

## Fixes made during this audit

GitHub main originally lacked the actual Activity/Application and export/backup validation files.
The recovered Activity also had an ambiguous `Surface` import and referenced a missing quote count.
The manifest did not register `QuranApp`, so an otherwise compiled launch would cast the wrong
Application type. Those blockers were corrected in the native sources.

The search core previously disabled gloss retrieval for Urdu because it detected Arabic script.
It also mixed lane scores, could satisfy multiple query tokens with one source word, and did not
retain useful variant/selection provenance. The replacement maintains separate indexes and bounded
matching, including exact negation. Short spelling repairs require surrounding query context.

Recall now supports exact source phrases, prevents passive exposures and paused/orphan ratings
from increasing recall, and rejects conflicting event identities. It does not infer a learned
root/sense from surface resemblance. Natural deferral is bounded and never hides a first lesson.

The scheduler audit also found that a first HARD review could be scheduled later than GOOD.
New reviews use `conservative-2`, with monotonic rating intervals. Existing `conservative-1`
review events are replayed with their recorded interval rule; old backups remain supported.
Large per-selection traces are omitted from Android saved-instance state to avoid oversized Binder
transactions; restored selections explicitly disclose when retrieval provenance is unavailable.
Arabic PDF alignment now follows paragraph direction. Its final visual QA still requires Android.

The source builder's release checks are explicit exceptions, so `python -O` cannot disable them.
The check runner refuses optimized mode rather than silently skipping its assertions.

## Verification evidence and limits

- 88 behavioral regressions passed: search, fragment segmentation/ambiguity/unmatched negation,
  provenance, Arabic/Hindi normalization, recall, natural-deferral bounds, transition/phrase
  identities, portable viewport anchors and evidence checks.
- All 6,236 coordinate queries resolved to their exact archived Arabic text.
- All 6,236 safe-token/source mappings and 6,122 within-surah transition excerpts were checked.
  A full-corpus mixed-quotation regression recovered both sources and exposed added negation.
- All 13 positive engineering search cases returned their expected coordinate in the top 10;
  20 engineered absent queries returned no results. This is not a scholarly benchmark.
- All 77,881 word ranges were compared with their source substring. Every ayah hash and the
  19 MiB content pack checksum were checked. Source data was not rewritten.
- Core and application Java compiled against Android API 35.
- Android `aapt2` compiled the resources and linked the manifest successfully.
- Full Gradle execution could not resolve Android Gradle Plugin 8.9.2 in this environment.
  No installable APK, emulator launch, actual phone test or pixel-perfect UI/PDF validation is claimed.
- The corpus regression process ran with a 256 MiB JVM heap cap. This is an engineering budget
  check, not measured Android process RAM, latency or a guarantee for a particular phone.

## Resume order

1. Run the checked-in offline verification command. Resolve Gradle dependencies in a configured
   Android environment, then test launch, RTL word taps/ribbon placement, transition/phrase reveal,
   viewport restoration after search/settings/rotation, large fonts,
   backup round-trips and PDF export on a real low-memory device.
2. Add reviewed lexical/sense mappings without overwriting existing word IDs or event history.
   Only then enable cross-context natural retrieval, morphology personalization and a richer model.
3. Introduce a versioned, measured scheduler adapter and bounded exposure/rare-word forecasting.
4. Add a rights-cleared Hadith edition with immutable citations and a reviewed retrieval benchmark
   before expanding to additional collections or semantic retrieval.
5. Add opt-in ambient delivery and signed pack updates after the deterministic foundations pass
   device and migration tests. Do not add a cloud dependency to read or review Quran.

## Boundaries of the new reading and retrieval features

- Transition targets use `Q:surah:ayah:T:nextAyah`. Both coordinates and consecutive source
  ordinals must exist in the same surah. An edge review does not increase either ayah's mastery.
  The displayed ending/opening are original source substrings with separate references.
- Reader anchors identify a code point and line offset, not a pixel scroll percentage. They are
  validated against the installed source during backup import. The ribbon uses free space above
  or below the tapped line; when neither area is tall enough it opens the existing detail sheet.
  Scrolling dismisses the ribbon. These behaviors compile but still need actual phone QA.
- Fragment assistance applies to a single original Arabic query when no whole safe-text phrase
  was found. It requires at least three consecutive matching words per excerpt and at least half
  of query words covered. It selects at most four nonoverlapping fragments and shows up to four
  source alternatives each, with total occurrence counts and unmatched spans. These are explicit
  engineering limits, not calibrated religious relevance/confidence thresholds.
- Fragment matches ignore the same reading marks as the safe search lane; they do not use typo
  repair, hamza folding, AI expansions or generated text. Full and partial matches remain distinct.
  JSON export retains exact code-point spans and original query; TXT/PDF disclose partial scope.
- Reviewed grammar/pronoun links, personal confusion-pair diagnosis and prerequisite teaching
  still need reviewed content and explicit learning evidence; no tap-based guess is presented as
  established comprehension. No new cloud service, account, network permission or paid model.

## Implementation references

- Android Application registration: https://developer.android.com/reference/android/app/Application
- SQLite FTS5/trigram behavior: https://www.sqlite.org/fts5.html (substring retrieval alone is not
  typo correction; this build uses explicit bounded token matching in its portable Java core).
- Exact content/license provenance remains in `source-vault`, `tools/source-lock.json` and the
  bundled source notices. Imported glosses are a non-commercial preview, not a reviewed Aaris tafsir.
