# Aaris Quran

A calm native Android Quran reader with a private learning ledger and local evidence search.

The front is a quiet Mushaf. The durable foundation is original source text, stable coordinates,
an append-only learning history and rebuildable indexes. AI never supplies scripture or citations.

## Build

Requirements: Python 3.10+, JDK 17, Android SDK 35. No paid service or API key.

```sh
python3 tools/build_content.py
python3 tools/prepare_open_hadith_data.py
python3 tools/build_hadith.py --source build/generated/hadith-source
./gradlew :core:coreCheck :app:assembleDebug
```

Progress and known limitations: [docs/PROGRESS.md](docs/PROGRESS.md).
Reader personalization, translations, recitation and research search: [docs/READER_PERSONALIZATION.md](docs/READER_PERSONALIZATION.md).
Architecture coverage and remaining work: [docs/ARCHITECTURE_STATUS.md](docs/ARCHITECTURE_STATUS.md).
The generated SQLite pack is not checked in; its archived sources and deterministic builder are.

Offline verification (without CI or an APK build):

```sh
python3 tools/build_content.py
python3 tools/prepare_open_hadith_data.py
python3 tools/build_hadith.py --source build/generated/hadith-source
python3 tools/check.py
python3 tools/check_hadith.py
# Also check native Java/resources when the Android SDK is available:
python3 tools/check.py --android-jar "$ANDROID_HOME/platforms/android-35/android.jar" \
  --aapt2 "$ANDROID_HOME/build-tools/35.0.0/aapt2"
```

This preview implements Quran reading, a meaning ribbon that preserves text layout, portable
reading anchors, source word meanings, opt-in word/phrase/ayah and consecutive-ayah transition
recall, Quran lexical/fragment search and evidence export. Mixed remembered quotations show
separate cited excerpts, ambiguous alternatives and unmatched words; they never become a new
source quote. The Yaad tab provides an opt-in timed overlay over other apps; Android
permission is required. The Hadith tab is local-only: it never opens Sunnah.com. A verified
explicit Hadith pack under `source-vault/hadith/active` has priority; otherwise the build derives
one immutable local evidence pack from checked-in sources. The Open-Hadith-Data core-nine contributes
62,169 **vocalized Arabic** records whose numbering and wording are checked against its pinned plain
edition. A separate HadeethEnc collection contributes 3,582 official Arabic records. Its hash-locked
official workbooks contain 2,328 English, 2,220 Urdu and 2,314 Hindi translation rows; after
cross-checking each translated row's embedded Arabic against the current official Arabic workbook,
the installed pack safely includes 2,327 English, 2,098 Urdu and 2,252 Hindi translations.
Rows with source-identity drift remain archived but are quarantined rather than guessed onto an
Arabic record. HadeethEnc stays separate instead of guessing one-to-one mappings onto
Bukhari/Muslim/etc. Normal builds use only
these archived files: no Hadith website or API is contacted. Local phrase/token search indexes
Arabic, Hindi, Urdu and English layers where present. This is not a claim that every collection in
the wider Sunnah.com catalog is vendored.

Today now opens the shared Appearance Studio: preset looks, independent card/button/highlight colors,
live preview, Quran/Naskh/Bold fonts, size/spacing, text depth/shadows/glass sheen, saved styles and undo/redo.
Complete archived Quran translations appear below ayahs with edition attribution: Hindi
Azizul Haq Al-Omari, Urdu Muhammad Ibrahim Junagarhi, English Rowwad Translation Center and
English Noor International/Saheeh. Arabic word taps stay available. Search accepts paragraphs and ranks textual
overlap, typo and supported pronunciation matches. One shared search box covers Quran and all installed Hadith books, accepts multilingual
collection + number references and vocalized/plain Arabic, and preserves separate narration IDs.
The search runtime also recognizes bounded book-name typos in English/Hindi/Arabic/Urdu. Exact
phrases use indexed pagination; fuzzy text uses bounded candidate ranking, SQLite cancellation
and independent Quran/Hadith workers. See [the runtime fix and checks](docs/SEARCH_RUNTIME_FIX_2026_09_24.md).
Search results can be selected and shared as a local, attributed PDF through Android's share sheet. Whole-ayah recitation adds an optional
Mishary/Al-Husary/Minshawi catalog, continuous playback and selected-reciter downloads.
It is separate from the isolated-word pronunciation system below. Core builds never fetch it.
Native resource/Java compilation and offline regressions pass; physical-device QA remains pending.
No APK was produced. See [the fix report](docs/SEARCH_READING_FIXES_2026_09.md) and the
[vocalized source report](docs/HADITH_VOCALIZATION_2026_09.md). The wider Sunnah catalog remains
separate unfinished content work; translated HadeethEnc evidence is a distinct source collection
and never silently replaces or annotates the Open-Hadith-Data core-nine records.

Quran word pronunciation uses on-demand **isolated word recordings** so the base APK stays small
without cutting words out of one continuous recitation. The reviewed source lock pins
`zaibihassan/Quranic-Word-By-Word-Audio-Data` at immutable revision
`9796e08caae700f44266255da320adf6e5ab4114` and the Muallim teacher-style Opus set. A one-time
maintainer packer groups the byte-identical source clips into 114 immutable `.aqp` Surah
containers plus a tiny hash catalog. The user may download one Surah from its reader screen or
choose Download All. Interrupted downloads keep a revision-scoped partial container and resume
with HTTP Range; only a fully SHA-256/index/Ogg-validated container becomes playable. Word taps and
ambient recall overlays address one complete source Ogg stream by byte range and play it from its
own beginning to natural completion — there is no full-Surah `seekTo()`, guessed timestamp stop,
TTS or re-encoding. Quran text, Hadith, search, learning and recall remain usable without audio or
internet. Normal Gradle/direct release builds never bundle Quran pronunciation binaries; only the
tiny catalog metadata is allowed in the APK. The upstream dataset metadata declares Apache-2.0;
this preview remains non-commercial pending independent recording-rights review. The remaining architecture still lacks the full wider
Hadith catalog, reviewed morphology/sense graph, calibrated FSRS and a signed general content-pack updater.

## Signed release APK + AAB

Release signing is wired through `app/build.gradle` without committing private key material. The
permanent upload identity is the Drive backup `Aarish-upload-keystore.jks`, alias `upload`.
Gradle verifies the expected signing-certificate SHA-256 before a configured release is packaged.

For local builds, copy `keystore.properties.example` to the ignored `keystore.properties`, fill
in the private path/password values, then run:

```sh
./gradlew --no-daemon --stacktrace \
  :app:assembleRelease \
  :app:bundleRelease \
  -PrequireReleaseSigning=true
```

This produces the signed APK at `app/build/outputs/apk/release/app-release.apk` and the signed AAB
at `app/build/outputs/bundle/release/app-release.aab`. The strict flag prevents an unsigned
release from being mistaken for a publishable build.

A manual GitHub Actions workflow, **Build signed release APK and AAB**, supports the same release
path once the private repository secrets are installed. See
[docs/RELEASE_SIGNING.md](docs/RELEASE_SIGNING.md) for the locked certificate fingerprint, secret
names, local setup, verification behavior and future `versionCode` update rules.

The dependency-free `tools/build_release.py` path remains available as an APK-only fallback when
the Android Gradle Plugin cannot be downloaded. It accepts the JKS directly and also supports an
optional separate private-key password file:

```sh
python3 tools/build_release.py \
  --android-jar "$ANDROID_HOME/platforms/android-35/android.jar" \
  --build-tools "$ANDROID_HOME/build-tools/35.0.0" \
  --keystore /private/path/Aarish-upload-keystore.jks \
  --alias upload \
  --password-file /private/path/keystore-password.txt \
  --output /private/output/Aaris-Quran-0.4.0-release.apk
```

Keep the signing key and password backup private and reuse the same certificate for every future
update.

## Source notices

Quran: Tanzil Project, Uthmani 1.1 — https://tanzil.net/ (original text unchanged).
Word glosses: Data Quran / Hablullah team, collected from Quran.com, pinned mirror commit
023b2f59edcf5cea0f4218a50039c6e6fc7154bc at https://github.com/mamun-al-abdullah/quran.
Those glosses are CC BY-NC-ND 4.0 and keep their original values. This bundled preview is
non-commercial: no paid sales, subscriptions or ads. They are imported source glosses,
not newly authored tafsir or independently reviewed Aaris meanings. Consult original sources.
Quran translations: QuranEnc snapshots archived unchanged with source/version metadata. Installed
editions are Hindi Omari, Urdu Junagarhi, English Rowwad and English Noor International/Saheeh.
Font: Amiri Project, SIL OFL 1.1. All notices are available offline inside the app.
Hadith: Open-Hadith-Data at `1515f6cba21efed20d8916bf55acef1dffa0d2d5`,
https://github.com/mhashim6/Open-Hadith-Data — ODbL 1.0 / Database Contents License.
Original vocalized CSVs and commentary are archived losslessly. The reader imports only the
narration column, removing redundant whitespace and U+200F layout markers while retaining every
Arabic letter and vowel mark. HadeethEnc official snapshots are separately archived at Arabic
v1.7.0, English v1.25.0, Urdu v1.36.0 and Hindi v1.59.0; their text is kept source-attributed and
indexed locally. No machine-generated Hadith translation or guessed cross-edition mapping is used.

## Recovery

Every checkpoint is a normal fast-forward commit. See docs/PROGRESS.md before resuming.
Never erase user learning or rewrite original source files to fix a UI/search issue.
