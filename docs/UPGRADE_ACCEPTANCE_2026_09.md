# Upgrade acceptance — 2026-09-23

Base: 02c339660f8542ccfdcfa66e2c67edf1ebab2291.
Delivery: isolated review branch, one [skip ci] commit. Not a release-ready claim.
No APK/AAB, CI workflow, new corpus download, source text edit, font binary edit,
audio mirror, or semantic model is part of this patch.

“IMPLEMENTED” below means code integrated in the patch. It does not mean compiled
or device-accepted. No previous pass's test counts are presented as this pass's results.

| Status | Scope |
| --- | --- |
| IMPLEMENTED, execution pending | Hard HIGH → MEDIUM → LOW ordering in both search paths; meaningful coverage, weighted overlap and phrase/order/proximity; transitive near-equal Bukhari/Muslim preference; match explanations |
| IMPLEMENTED, execution pending | Explicit local query shortcuts, pack binding, 180-day expiry, bounded retention and clear/reset; shortcuts kept separate from result ranking |
| IMPLEMENTED, execution pending | Study entry in reader and Today, available translation comparison, persistent pins/collections, existing notes/Recall integration, attributed copying and local translation issue drafts |
| IMPLEMENTED, execution pending | Existing Appearance model extended with saturation, text opacity, glass/border strength, subtle glow, two-color backgrounds, reduced effects and Easy Reading; real translation preview |
| IMPLEMENTED, execution pending | Six research tasks, in-app comparison of 2–10 records, PDF instructions separated from evidence, selected prompt in share intent and explicit clipboard action |
| IMPLEMENTED, execution pending | Android voice-search adapter with provider notice; offline device translation-voice choice and sample; missing Quran edition no longer silently falls back |
| IMPLEMENTED, execution pending | Restore validation for translation_edition and bounded new study/shortcut/draft data in existing user-data transactions |
| PARTIAL | Hadith research: existing 62,169 Arabic records preserved; no new multilingual/phonetic corpus, matn/isnad index, grade filter or curated narration-family mapping |
| PARTIAL | Search learning is exact-query confirmation, not general spelling learning. No semantic model, keyboard-neighbor model, joined-word segmenter, benchmark calibration or universal cross-corpus score |
| PARTIAL | Study does not include new Tafsir, root/lemma datasets, curated Quran–Hadith relations, navigation units, translation-only mode, playlists or reading plans |
| PARTIAL | Audio engine unchanged: background download queue, byte-range resume, sleep timer/range repeat, reconciliation and lifecycle resilience remain |
| BLOCKED-BY-DATA-RIGHTS / REVIEW | No reviewed, versioned, redistribution-cleared new Hadith translations/grades, remaining collections, Urdu display editions, Tafsir, morphology, Tajweed or alternate Mushaf profiles were acquired in this pass. This is not a claim that all potential sources prohibit reuse |
| MODEL / EVALUATION REQUIRED | Exact recitation mistake, pronunciation, harakat and Tajweed assessment; ordinary speech-to-text cannot substantiate these claims |
| NEEDS-DEVICE-QA | All changed native UI, voice providers, backups, rendering, share destinations and existing media lifecycle; Android compilation also remains pending |

## Validation evidence and limits

The execution environment reported “503 Service Unavailable,
environment_status_unavailable”. No shell, JVM, Android SDK, emulator or device
execution capability was exposed. Therefore:
- Core JVM tests: NOT RUN in this pass.
- Full 6,236-coordinate/hash and translation rebuild: NOT RUN in this pass.
- Hadith 62,169-record rebuild/integrity: NOT RUN in this pass.
- Android Java/resource compilation: NOT RUN.
- Device visual, media and share-app tests: NOT RUN.
- No full suite, APK/AAB build or CI was invoked.

Source review checks exact edit anchors, changed-file scope, balanced Java lexical
structure and cross-file call sites. This does not replace Java type checking or
runtime validation. Source-vault assets, canonical text/IDs, hashes, offsets and
content builder inputs are unchanged in the commit tree.

RankingChecks adds fixtures with a numerically higher MEDIUM score than HIGH,
near-equal but unequal source scores, cross-band source protection and comparator
transitivity. Existing long-input, duplicate-token, negation and typo checks remain.
These fixtures are committed for the next executable validation pass; they have
not been run here.

## Required verification before merge

1. Run existing local content/Hadith build scripts and one consolidated
   tools/check.py pass, with --android-jar and --aapt2 where available.
   Do not build an APK/AAB or invoke CI. Resolve failures, not by weakening gates.
2. Confirm all installed corpus counts, coordinate hashes, word spans and translation
   edition coverage. Check Quran Roman/Devanagari regressions after rank changes.
3. Exercise Hadith global pagination and source buckets across 62k records; inspect
   absent/negated queries and result stability. Benchmark low-RAM devices separately.
4. On device verify Study → word details/Recall, pin limit, multiple collections,
   backup export/restore, malformed IDs and over-limit JSON rejection, query shortcut
   expiry/pack mismatch/reset, and translation feedback sharing only on user action.
5. Verify old saved styles, undo/redo/reset, each advanced control, reduced effects,
   high contrast, RTL, landscape and 200% fonts. No clipping of Arabic marks.
6. Verify speech provider absent/cancelled/rotation, offline preference notice,
   saved device voice missing, sample stop and Activity destruction.
7. Share PDFs with each task into installed PDF receivers, including ChatGPT/Gemini
   where supported. Check separate citations, original Arabic, attribution, selected
   scope, prompt text and RTL rendering. Never mark this complete from source alone.

Deferred data/model features need reviewed packs, source/license/version/hash
evidence and measured accuracy before enabling user-facing claims. Unavailable
features are not represented by fake selectors or placeholder religious content.
