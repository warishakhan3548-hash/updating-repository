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

## Checkpoint 6: final audit and verification (2026-09-22)

- Published the full implemented/partial/missing matrix in `docs/ARCHITECTURE_STATUS.md`.
- Corrected first-review HARD intervals being longer than GOOD. New events use conservative-2;
  old conservative-1 events replay their recorded rule, and old backups remain accepted.
- Source validation now survives Python optimized mode; the test runner rejects `-O`.
- Bounded Android saved-state trace size and made missing restored provenance explicit.
  Corrected RTL PDF paragraph alignment without altering any source text.
- Final validation: 52 core checks, 6,236 coordinate lookups, 13 positive and 20 absent search
  cases, source/word integrity, Android Java compile, and native resource/manifest linking.
- No CI workflow, APK build, phone test, complete FSRS, Hadith corpus or semantic model is claimed.
- Git CLI writes lack credentials in this environment. Checkpoints were published through the
  connected GitHub app using non-forced branch updates; remote tree hashes are compared with the
  local tested commit before each update. Resume from GitHub main, not an interrupted old clone.

## Checkpoint 7: stable reading, transition recall and quotation fragments (2026-09-22)

- Added a single meaning ribbon placed above/below the tapped source line, persistent word
  highlight without reshaping text, and source-coordinate viewport anchors across reader rebuilds,
  search return, saved state and pause/restart. Small screens fall back to the detail sheet.
- Added canonical directed transition targets, validated against consecutive source ayahs. Practice
  shows the ending of one ayah and asks for the next opening, with separate citations and its own
  recall history. Existing word/phrase/ayah state and versioned scheduler history are untouched.
- Added safe-token/source-offset mapping and bounded fragment retrieval inside search lexical-4.
  Nonoverlapping segmentation recovers separate source excerpts without constructing a quotation.
  Ambiguous occurrences, unhandled query words and original ranges remain explicit in UI/export.
- Backup validation accepts the new source-checked transition and viewport identities. Existing
  schema-1 histories still replay with their recorded scheduler; no schema reset or source edits.
- Verification: 88 core checks, 6,236 coordinate and safe-token mappings, 6,122 transition excerpts,
  mixed-source/unmatched-negation corpus regressions, existing 13 positive/20 absent queries,
  Android API-35 Java compilation and native resource linking all pass.
- No emulator/phone run, APK, Hadith pack, reviewed grammar model or complete FSRS is claimed.

## Checkpoint 8: lifecycle and reading-context audit (2026-09-22)

- Viewport restoration now waits for native text layout's pre-draw event. A pause/rotation before
  that event cannot replace the pending saved anchor with the temporary zero-scroll position.
- Natural occurrence lookahead and the resume label now use the visible anchored ayah, rather
  than always assuming the first ayah of an eight-ayah page. Quiet-reader mode survives rotation.
- Backup validation resolves both transition ayahs and checks anchor offsets against the source;
  old event/schema versions remain supported without clearing history. Runtime backup round-trip
  and document-provider process-death checks still require Android.
- The absent-query corpus guard also rejects unexpected fragment suggestions. Final source/core,
  corpus, Android Java and native resource checks were repeated for the completed code snapshot.

## Checkpoint 9: release audit and durable export handoff (2026-09-22)

- Audited the installed SQLite pack: 6,236 ayahs and 77,881 word ranges; zero Hadith records.
  Bukhari, Muslim, Abu Dawud, Tirmidhi, Nasai and Ibn Majah are not bundled. A release build must
  not present the placeholder tables as installed collections.
- Fixed the file-picker rotation/recreation bug: export bytes are now privately staged on disk;
  saved Activity state contains a checksum-bound opaque token, not a volatile byte array.
  Staged payloads are checked before copying; cancellation removes the matching handoff only.
  Both import and export use a 64 MiB byte bound. Large-history Android memory testing is pending.
- Guarded duplicate export requests, missing document-picker apps and dead-Activity callbacks.
  Closed the meaning ribbon when opening a sheet, restored the reader keyboard state, applied
  settings on close/back as well as Done, and accounted for display cutouts/navigation insets.
- Added six disk-backed handoff regressions: recreated store, failed destination retry, corrupted
  payload, invalid token and scoped cleanup. 94 core checks plus corpus/source/API checks pass.
- Standard Gradle release assembly could not resolve AGP 8.9.2 from the configured repositories.
  Added a bounded official-SDK release builder (aapt2, javac, D8, zipalign, apksigner) that refuses
  extra dependencies, takes an external signing key and verifies its output. No CI/AAB required.
- Version metadata is 0.2.0 / code 2. Signing secrets must remain outside git. The APK's exact
  checksum, signer and source commit will be recorded after successful release assembly.

## Checkpoint 10: signed release APK delivered (2026-09-22)

- Release APK 0.2.0 / code 2 was built from clean GitHub source `95dbb29` with official SDK tools.
  Corrected the release verifier for current AAPT2's `minSdkVersion` output label. Keystore and key
  use the same private password; apksigner reuses the store password instead of consuming one
  single-line password file twice.
- APK size: 6,685,661 bytes. APK SHA-256:
  `effef175eaf394903996851b9eb12aa9493388d87155b428cb44214bcbf1a8ba`.
- Release signature v2/v3, zip alignment, package/API/debug flags, ZIP CRC, DEX checksums/entry
  points and original embedded Quran-pack checksum all pass. No AAB or CI workflow was generated.
- Delivered the APK, public verification JSON and a private signing-recovery archive. Signing
  secrets remain outside git. Preserve the recovery archive for future compatible APK updates.
- See `docs/RELEASE_0.2.0.md` for exact results and runtime limits. There is still no emulator/phone
  validation or installed Hadith corpus. Do not claim full architecture completion or zero bugs.

## Checkpoint 11: native ambient recall and navigation redesign (2026-09-22)

- Added a portable monotonic timer and source-validated rotating recall selection. The Android
  service owns exactly one TYPE_APPLICATION_OVERLAY window and is started explicitly by the user.
  The app requests Android overlay consent and optional notification permission. No usage access,
  accessibility service, exact alarm, wake lock, network permission or boot autostart was added.
- Session interval is 1–120 minutes (default 5); switching external apps keeps the same timer.
  Locking the phone or opening Aaris pauses it. Dismissal resets the interval. Cards automatically
  dismiss after two minutes without counting an answer. Stop is available on the card, in the app
  and in the ongoing notification. Process termination requires explicit restart.
- Words, phrases, ayahs and transitions use source text and the existing event ledger. Showing,
  dismissing or revealing never proves recall. Optional due-only mode abstains when nothing is due.
- Added 10-second test delivery and a source-backed item picker. Device-local session settings
  never turn overlays on through a restored learning backup.
- Reworked glass colors/surface roles, responsive reading controls, Arabic chapter header,
  verse spacing, primary buttons, touch feedback and floating four-tab navigation.
- Hadith has a dedicated tab: all six source collections and external Sunnah.com search are
  visible. They require a browser/internet. Zero offline Hadith records are still bundled;
  external search is not represented as the local evidence engine.
- 113 core regressions, all corpus/source checks, API 35 Java compile and AAPT2 resource/manifest
  linking pass. Actual Android overlay delivery and visual/device QA are still pending.
- Version is 0.3.0 / code 3. Build an updated signed release APK with the existing private key.

## Checkpoint 12: overlay release hardening (2026-09-22)

- Permission-result callbacks now wait for the Activity to resume before starting the foreground
  service, and deferred launch state survives recreation. API 30+ overlay views use the native
  display/window context rather than service-resource metrics.
- Raised small-text contrast, kept close/stop outside the scrolling overlay body, and fixed
  a settings-dismiss listener that could redraw after its owning Activity was being destroyed.
- Added docs/AMBIENT_RECALL.md with the delivery contract, platform references, and an explicit
  not-yet-run physical-device acceptance list. No device validation is implied by compilation.

## Checkpoint 13: overlay release APK delivered (2026-09-22)

- Built 0.3.0 / code 3 from clean GitHub source `b12c7a2` with the existing release key.
- APK: 6,702,130 bytes; SHA-256
  `474743d483889b5dc21ed24fed1ea365220eac7ad7ff0e31587524e14d15940f`.
- Release signature, alignment, source pack, ZIP/DEX checksums, overlay classes and final
  permission metadata pass. Signer matches 0.2.0. APK and verification JSON were saved.
- See docs/RELEASE_0.3.0.md for exact evidence. Real device UI/overlay/update testing remains
  pending; Hadith source browsing is online and the offline Hadith record count remains zero.
