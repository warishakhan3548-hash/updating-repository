# Aaris Quran — persistent engineering checkpoint

User direction: native Android Quran comprehension, quiet memory and evidence research;
teal/blue/gold glass UI. Repository main was intentionally cleared at 32d9eef.

## Checkpoint 1: source foundation (2026-09-22)

- Android Java 17 application + portable Java core. Android 8+; no runtime network requirement.
- Original Tanzil Uthmani 1.1 restored from the user's earlier frozen vault, SHA-256 checked.
- Amiri Quran font from its official project; original OFL included.
- Source-tagged English/Hindi/Urdu word glosses and transliteration from a pinned Data Quran snapshot.
  Non-commercial preview only. Upstream source assertions are preserved; this is not an independent
  scholarly review or a commercial rights clearance.
- Deterministic SQLite builder preserves original ayah text including prefatory basmala.
  Strict per-ayah Arabic alignment; mismatched glosses are withheld, never guessed.
- All 114 surahs / 6,236 ayah coordinates validated.

## In progress

Native glass reader, event ledger, recall, local search, source viewer and manual backup.
This checkpoint is not yet a buildable finished application. Run the content builder offline.

## Explicit later gates

Scholarly gloss/sense/morphology review; edition-cleared Hadith packs; calibrated FSRS adapter;
ambient delivery device tests; signed remote pack updates; licensed audio; semantic model benchmark.
No placeholder is to be reported as a working feature.

## Checkpoint 3: interrupted-work recovery (2026-09-22)

Inspection of main at `e927628` found that the font, wrapper JAR and six word-source
JSON files were missing from GitHub. Recovered the exact files from the previous
workspace, checked all 13 source SHA-256 values against the committed manifest,
and reproduced the existing pack checksum. A source lock now rejects missing or
changed archived inputs before generating a pack. The native reader/application
entry points were also found locally and are being reviewed before publication.

Content validation: 114 surahs, 6,236 ayahs, 77,881 word ranges, 77,766 aligned
source glosses; 9 ayahs with mismatched mappings are deliberately withheld.
No APK has been built. Android Lint startup was attempted, but Java could not
download the Gradle distribution; analyzer setup is still in progress.

## Checkpoint 4: recover the actual application (2026-09-22)

- Started from GitHub main `8eb4bee`, preserving the interrupted workspace separately.
- Recovered the missing native MainActivity, QuranApp, backup validator and evidence exporter.
- Fixed the manifest's missing Application registration, ambiguous Surface import and missing
  checked-quote counter. These were actual launch/compile blockers, not UI polish.
- Restored pending transactional backup validation, cancellable Urdu/multi-query search and
  content-build Gradle wiring from the interrupted work.
- Added an offline regression runner: `python3 tools/check.py --android-jar <android.jar>`.
  This validates source hashes/ranges, startup registration, core behavior and Java compilation.
- Full Gradle validation remains blocked by unavailable Android Gradle Plugin resolution in this
  environment. Direct API-35 Java compilation is a narrower check, not a device launch or APK test.
- The architecture is still incomplete. Next: reliable query provenance, phrase recall and
  honest implementation coverage. Do not present placeholder Hadith tables as Hadith search.

## Checkpoint 5: retrieval and recall core (2026-09-22)

- Replaced the mixed search scorer with separate Arabic/gloss BM25 indexes, bounded spelling
  candidates, rank fusion and full query-token coverage. Repeated tokens require separate source
  occurrences; negations are never typo-repaired away. Original/normalized variants and USER/AI
  origin survive in the response. Repeated variants get one vote. Oversized input is rejected
  visibly instead of silently truncated. No network/model dependency was added.
- Canonical phrase targets (`Q:surah:ayah:P:first-last`) resolve to exact immutable source ranges.
  Word, phrase and ayah recall use the same event ledger. New memorization items have an explicit
  read -> hide -> recall -> reveal -> self-rate flow. Paused/orphan ratings cannot grow memory.
- Natural deferral is wired only for the exact saved word occurrence, capped at one day, and
  cancelled by fresh difficulty. Surface similarity still does NOT imply a reviewed shared sense.
  The reader offers a small opt-in recall action when a saved due word is on the page.
- Export now preserves per-record retrieval reasons/query provenance. Manual reader selections
  are labelled separately. Unsupported quotes/malformed references cannot get a passing check.
  Verification consults the installed immutable source, not just a self-consistent imported hash.
- Improved search cancellation, multiline query entry, insets, selection restoration and native
  glass reader ornament. No GPU blur is applied to Quran glyphs.
- 42 behavioral checks, all 6,236 coordinate lookups, 13 corpus retrieval regressions and 20
  engineered absent queries pass. Full app Java compiles against Android API 35. The small query
  set is engineering regression coverage, NOT a scholarly search evaluation or phone benchmark.
