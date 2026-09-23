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

## Checkpoint 14: Image 2 smoked emerald design (2026-09-22)

- Applied the user's selected Image 2 direction in native UI code: near-black background,
  desaturated emerald glass surfaces, softer ivory text, thin rims and separate ayah cards.
  Cards receive their surface role directly; no stacked theme overrides or image-based Quran.
- ArabicText provides one shared native glyph finish for the reader, meanings, search, recall
  and overlay: a cached repeating line gradient plus a short dark contact shadow. Android
  continues to shape the original Arabic and diacritics with the existing Amiri Quran font.
- Preserved source word offsets, taps, recall events and reader anchors. Selected ayahs use
  plain glyph paint so Android's BackgroundColorSpan does not inherit the glass shader/shadow.
  High contrast also disables the finish; its settings sample updates immediately.
- Replaced per-frame surface gradients with cached drawables and corrected primary-button
  text for the darker palette. No bitmap text, live blur, animation or new dependency added.
- Validation: 113 existing portable core checks pass; all 28 Java files parse and theme XML
  parses. Opaque palette estimates: dimmest Arabic face 7.50:1, muted metadata 5.91:1 against
  the brightest reader-card stop (before edge antialiasing). These are not device measurements.
- No Android SDK or emulator is available in this workspace, so Android API compilation and
  on-device rendering remain unverified for this change. No APK/AAB was built, no release
  workflow was started, and the previously delivered 0.3.0 APK keeps its earlier design.


## Checkpoint 15: full offline Hadith pack foundation (2026-09-23)

- Expanded the Hadith target from the original six links to the full current Sunnah.com top-level
  catalog planning set (26 entries, plus the nested Forty collections) in
  `tools/hadith-catalog.json`. This is catalog metadata only; it does not copy Hadith text.
- Added `docs/HADITH_OFFLINE_ARCHITECTURE.md`: Quran and Hadith remain separate immutable packs,
  with edition-aware IDs, alternate references, attributed grades, per-layer provenance and a
  separate editable Aaris-authored translation/explanation layer.
- Added `tools/build_hadith.py`, a deterministic network-free JSONL-to-SQLite builder. It refuses
  missing licenses/permission records, hash mismatches, duplicate Hadith IDs, broken references and
  empty packs. It does not scrape or download any website.
- No Hadith corpus has been imported yet. The existing app must not claim these collections are
  locally installed until redistribution-cleared source files are added and validated.
- No APK/AAB was built and no CI workflow was started.


## Checkpoint 16: local-only Hadith runtime and acquisition pipeline (2026-09-23)

- Removed the Hadith runtime dependency on Sunnah.com. The Hadith tab now opens only a bundled,
  checksum-verified read-only pack; without a pack it reports that local Hadith content is not
  installed and never falls back to a browser.
- Added collection -> book -> chapter -> Hadith navigation, pagination, exact reference/number
  lookup and background local text search. The generated pack includes an FTS4 index over
  normalized Arabic/English search shadows while preserving display text byte-for-byte.
- Added an isolated `HadithStore`; a missing or bad Hadith pack no longer prevents the verified
  Quran pack and user learning database from opening.
- Hardened `tools/build_hadith.py`: SHA-256 locked source and permission files, edition-aware
  identities, source text hashes, attributed grades, alternate references, separate Aaris
  editorial-translation records, full-catalog coverage gate, foreign-key/integrity checks and
  generated pack manifest.
- Added `tools/acquire_sunnah_api.py`: a resumable one-time importer for Sunnah.com's documented
  API. It requires an environment-only API key plus operator-supplied redistribution/offline
  permission evidence, stores raw snapshots locally, splits normalized records per collection and
  finalizes the active manifest only after validation. It does not scrape website pages.
- The planning catalog covers all 26 current top-level Sunnah.com entries plus nested Forty
  collections. Large raw snapshots are Git-LFS-ready.
- `tools/check.py` now builds a synthetic Hadith fixture offline and verifies schema, FTS,
  source hashes and foreign keys even when the real corpus is absent.
- The actual full Hadith corpus is still intentionally **not claimed as installed**: no Sunnah.com
  API key/offline dump and redistribution permission were available in this session. Importing
  third-party scraped copies would violate the source-integrity/permission gate.
- No APK/AAB was built and no CI workflow was started.


## Checkpoint 17: vendored Arabic Hadith core-nine wired into build (2026-09-23)

- Vendored the Arabic source corpus for the nine primary books from Open-Hadith-Data into
  `source-vault/hadith/open-hadith-data/`. Large Bukhari, Muslim and Musnad Ahmad files are stored
  as byte-preserving parts; the other source files are stored directly.
- Added the upstream ODbL/Database Contents License text and `SOURCE.json` pinned to upstream
  commit `1515f6cba21efed20d8916bf55acef1dffa0d2d5`, including original Git blob identities.
- Added `tools/prepare_open_hadith_data.py`. It runs without network access, reconstructs split
  files, verifies the exact upstream Git blob SHA-1 before parsing, rejects malformed/duplicate
  records and generates a SHA-256 locked Arabic-only Aaris source pack.
- Wired Gradle so an explicit `source-vault/hadith/active` pack remains highest priority; if no
  explicit full pack exists, the verified vendored nine-book Arabic pack is generated and fed into
  `tools/build_hadith.py`. There is no website fallback at runtime.
- Added license/provenance text to the Hadith library UI. The app keeps Quran available even if an
  optional Hadith pack fails verification.
- This is real local source coverage for nine collections, not a claim that the full Sunnah.com
  catalog has been acquired. The remaining catalog entries still require redistribution-cleared
  source material or an approved official API/offline snapshot.
- No APK/AAB was built and no CI workflow was started.


## Checkpoint 18: core-nine Hadith source completed and fail-closed (2026-09-23)

- Completed the previously truncated Musnad Ahmad vendor: records now continue from 21,093 through
  26,363. The split source totals exactly 14,546,451 bytes, matching the pinned upstream file size.
- Verified the three split corpora against the pinned upstream source text: Bukhari's 9 parts match
  the complete upstream text exactly, Muslim's 7 parts match exactly, and Ahmad's 25 parts form
  three consecutive exact upstream chunks from the first byte through the final byte.
- Verified the six direct vendored files have the exact upstream Git blob identities recorded in
  `SOURCE.json`: Nasa'i, Abu Dawud, Tirmidhi, Ibn Majah, Muwatta Malik and Darimi.
- Locked expected contiguous record coverage in `SOURCE.json`: Bukhari 7,008; Muslim 5,362;
  Nasa'i 5,662; Abu Dawud 4,590; Tirmidhi 3,891; Ibn Majah 4,332; Malik 1,594; Ahmad 26,363;
  Darimi 3,367 — total **62,169 Arabic records**.
- `prepare_open_hadith_data.py` now fails closed on wrong counts, first/last IDs, gaps, duplicates
  or reconstructed Git-blob mismatch before it can create an installable source pack.
- `build_hadith.py` now rejects runtime-network packs and unsafe source paths, validates the
  editable Aaris translation status layer, carries language coverage into the generated manifest,
  and treats nested Forty collections as real full-catalog targets rather than the grouping card.
- Gradle now tracks explicit/generated Hadith source directories as task inputs, preventing stale
  `hadith.sqlite` assets when the local source changes.
- Runtime reading now supports a separate Aaris editorial translation layer. Released/reviewed
  local translations can change independently without rewriting the immutable Arabic source;
  source translations remain a fallback with provenance.
- Added `tools/check_hadith.py`: a network-free end-to-end verifier that reconstructs the pinned
  source, expects 9 collections / 62,169 records, builds a temporary SQLite pack, checks FTS,
  foreign keys, per-record source hashes and per-collection coverage. It does not build an APK.
- The full Sunnah.com catalog is still not falsely marked as installed. Additional collections
  remain gated on redistribution-cleared source data or approved official API/offline data.
- No APK/AAB was built and no CI workflow was started.

## Checkpoint 19: Quran word-audio offline release hardening (2026-09-23)

- The Quran pronunciation architecture is now repository-local by design. The reviewed source lock
  pins one immutable Muallim OPUS snapshot, the exact canonical `quran.sqlite` hash and exactly
  77,326 safe `SOURCE_ALIGNED :W:` identities. Acquisition is an explicit maintainer-only step;
  Gradle, normal verification, Android runtime and the direct SDK release builder never acquire
  Quran audio from the network.
- The local packer content-addresses every source clip, stores identical audio bytes once, and
  compacts unique clips into contiguous seekable chunk `.pack` files capped at 32 MiB plus a
  SHA-256 locked SQLite byte-range index. Runtime resolves canonical Word IDs to exact local
  `pack_id + offset + length` ranges and uses one process-wide player; unaligned/prefatory
  identities are never guessed.
- Active packs fail closed on source-lock mismatch, Quran-core mismatch, incomplete coverage,
  corrupt Ogg clip boundaries, index corruption, pack hash/size mismatch, unsafe paths and the
  reviewed ordinary-Git size envelope. A partial `active/quran-audio` directory now triggers
  verification instead of being silently ignored.
- Added a network-free synthetic audio self-test and wired it into `tools/check.py`. It prepares
  a tiny local pack, verifies it, corrupts it, and requires the verifier to reject that corruption.
  Manual offline verification also enforces the Android/build no-network contract.
- Hardened the official-SDK release builder so it now mirrors local Hadith selection, verifies any
  active Quran audio pack, includes its manifest/index/all manifest-declared chunk assets, stores `.pack` assets
  uncompressed for `AssetFileDescriptor` playback, and verifies the packaged hashes and byte sizes.
  This closes the previous gap where Gradle understood local audio/Hadith but the direct release
  path could omit them.
- Added a tracked `source-vault/quran-audio/release-policy.json` deletion guard. It is currently
  `pending_vendor_import`, so builds remain offline and valid without pronunciation while the
  binary payload has never been installed. The one-time completion script changes it to
  `required` only after full verification and pins the exact manifest SHA-256 + pack ID; after
  that, deleting/replacing the local pack makes Gradle, manual verification and direct release
  builds fail closed instead of reacquiring anything online.
- The actual large `source-vault/quran-audio/active` binary payload is **not yet committed** on
  GitHub. The remaining content step is to run the pinned one-time acquisition/finalization in a
  maintainer environment with network access, verify it, and commit the resulting ordinary Git
  files together with the armed release policy. Until those bytes exist, builds remain fully
  offline but word pronunciation is unavailable rather than falling back to a website.
- No APK/AAB was built and no CI workflow was added.



## Checkpoint 20: small base APK + on-demand local Surah recitation (2026-09-23)

- Replaced the planned monolithic repository/APK Quran audio payload with an on-demand Surah model.
  The base APK no longer includes Quran recitation bytes and normal Gradle/direct-release builds
  reject the old bundled audio directory if it is present.
- Pinned `zaibihassan/Quranic-Recitation-Data` at immutable revision
  `6875b35e45cc83107daf3ab7d3a8bd8b2baa51b3` and selected Abdul Basit Abdul Samad
  (Mujawwad) for original human Tajweed-oriented recitation. No TTS or generated voice is used.
- Every downloadable Surah is one full Ogg Opus recitation plus one compact protobuf timing file.
  A dependency-free protobuf decoder maps canonical Quran word coordinates to millisecond ranges.
  Word playback seeks the original local Surah recording to the word range rather than storing
  77,000+ separate clips.
- Added explicit user-controlled per-Surah download and Download All. Downloads use the immutable
  source revision, validate HTTPS/Ogg/timing structure, stage privately, then atomically replace the
  installed Surah directory. Incomplete downloads never become active.
- Downloaded audio lives only in app-private local storage. Once a Surah is installed, reader word
  taps, replay, and the existing cross-app recall overlay all use that local recording. The overlay
  never starts a download by itself; without the Surah pack it remains silent while recall still
  works.
- Runtime network access is isolated to `QuranAudioDownloadManager`; Quran text, Hadith, search,
  learning and recall remain offline-first. The static offline-contract guard now enforces that
  no other runtime class imports a network client.
- Added an `Audio ↓ / Audio ✓` control on each Surah reader and a `Quran audio · Download All`
  control in settings. Base APK size is therefore independent of how much recitation the user later
  chooses to store.
- Real-device Opus seek accuracy, slow/interrupted-download behavior and final installed/release
  size measurements still need physical Android QA. No APK/AAB was built and no CI workflow was run.

## Checkpoint 21: reader personalization, translations and ranked research (2026-09-23)

- Today → Personalize Aaris opens one shared Appearance Studio with live preview, six starting
  palettes, independent colors, glass/plain finishes, real Amiri Quran/Naskh/Bold fonts,
  size/spacing, undo/redo and named saved styles. Word taps and original Quran text remain intact.
- Archived Hindi/Urdu/English QuranEnc translations cover 6,236 ayahs each and build locally
  into a separate checksum-verified SQLite pack. Source edition, version, footnotes and notices
  stay attached. No build-time website fetch or automatic Urdu script conversion is introduced.
- Quran paragraph search now scores all pasted lines together. Full and partial overlaps,
  bounded spelling repairs and supported Roman/Devanagari pronunciation shadows return original
  source records. Hadith search uses a generated global token index across all installed books,
  preserves separate narration IDs and uses Bukhari/Muslim only to break equal relevance scores.
- Search exposes local PDF sharing of selected/loaded complete records, source references and
  match labels through temporary read-only URI grants. The export count/scope is explicit;
  copying an AI research prompt is an explicit separate action.
- Mishary, Al-Husary and Minshawi whole-ayah playback is a separate optional remote catalog with
  user-triggered downloads, continuous/repeat playback and a foreground media notification.
  Existing word pronunciation now uses the repository's pinned isolated clips, superseding
  Checkpoint 20's timestamp-slicing description. Whole-ayah audio is not mirrored into GitHub.
- Validation: 123 JVM core checks, 15/15 full-corpus retrieval cases, 20 absent queries, all
  6,236 coordinates and 77,881 word ranges passed. The real core-nine Hadith pack rebuilt with
  62,169 records. Three translation editions total 18,708 records. Corpus MRR@10 was 0.967
  on this small engineering set; this is not a scholarly accuracy or phone-speed benchmark.
- Android SDK/device compilation, visual checks, PDF receiving apps and media lifecycle QA
  remain pending. No APK/AAB or CI run. See READER_PERSONALIZATION.md for the exact feature
  scope and remaining transliteration, Hadith language and advanced retrieval work.
