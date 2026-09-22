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
