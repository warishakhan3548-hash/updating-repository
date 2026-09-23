# Aaris Quran

A calm native Android Quran reader with a private learning ledger and local evidence search.

The front is a quiet Mushaf. The durable foundation is original source text, stable coordinates,
an append-only learning history and rebuildable indexes. AI never supplies scripture or citations.

## Build

Requirements: Python 3.10+, JDK 17, Android SDK 35. No paid service or API key.

```sh
python3 tools/build_content.py
# Optional: only after source-vault/hadith/active/manifest.json contains a cleared local pack
python3 tools/build_hadith.py --source source-vault/hadith/active
./gradlew :core:coreCheck :app:assembleDebug
```

Progress and known limitations: [docs/PROGRESS.md](docs/PROGRESS.md).
Architecture coverage and remaining work: [docs/ARCHITECTURE_STATUS.md](docs/ARCHITECTURE_STATUS.md).
The generated SQLite pack is not checked in; its archived sources and deterministic builder are.

Offline verification (without CI or an APK build):

```sh
python3 tools/build_content.py
python3 tools/check.py
# Also check native Java/resources when the Android SDK is available:
python3 tools/check.py --android-jar "$ANDROID_HOME/platforms/android-35/android.jar" \
  --aapt2 "$ANDROID_HOME/build-tools/35.0.0/aapt2"
```

This preview implements Quran reading, a meaning ribbon that preserves text layout, portable
reading anchors, source word meanings, opt-in word/phrase/ayah and consecutive-ayah transition
recall, Quran lexical/fragment search and evidence export. Mixed remembered quotations show
separate cited excerpts, ambiguous alternatives and unmatched words; they never become a new
source quote. The Yaad tab provides an opt-in timed overlay over other apps; Android
permission is required. The Hadith tab is now local-only: it never opens Sunnah.com. A verified
explicit Hadith pack under `source-vault/hadith/active` has priority; otherwise the build derives
the checked-in, hash-locked Open-Hadith-Data core-nine Arabic source into a local `hadith.sqlite`.
That local pack supports Collection → Book → Chapter → Hadith navigation and local Arabic/
English/reference search where those language layers exist. This is real offline core-nine coverage,
not a claim that every collection in the wider Sunnah.com catalog is vendored.

Quran pronunciation now uses an on-demand local Surah architecture instead of putting hundreds
of megabytes of recitation inside the base APK. The reviewed source lock pins an immutable
`Quranic-Recitation-Data` snapshot and Abdul Basit Abdul Samad (Mujawwad). Each Surah is one
original human-recitation Ogg Opus file plus compact word-level protobuf timings. The user may
download one Surah from its reader screen or choose Download All. Interrupted downloads are kept
as revision-scoped partial files and resume with HTTP Range when the origin supports it; a partial
Surah is never playable. A verified Surah is atomically installed into app-private storage; after
that, word taps and ambient recall overlays seek the local file and do not use the network. Quran text, Hadith, search, learning and recall remain usable
without audio or internet. Normal Gradle/direct release builds never download or bundle Quran
recitation bytes, so the base APK stays small. The upstream dataset metadata is tagged Apache-2.0,
but its own data-license notice says recording ownership may belong to reciters/studios/original
sources; this preview therefore treats recording rights as not independently cleared and remains
non-commercial pending separate rights review. The remaining architecture still lacks the full wider
Hadith catalog, reviewed morphology/sense graph, calibrated FSRS and a signed general content-pack updater.

## Signed release APK without Gradle downloads

For this native Java app with no external runtime dependencies, the installed official SDK tools
can produce the release APK directly. This is useful when the Android Gradle Plugin cannot be
downloaded. The script refuses unhandled dependencies and verifies the signature, alignment,
package flags and bundled scripture checksum. It does not claim a phone/emulator test.

```sh
python3 tools/build_release.py \
  --android-jar "$ANDROID_HOME/platforms/android-35/android.jar" \
  --build-tools "$ANDROID_HOME/build-tools/35.0.0" \
  --keystore /private/path/aaris-quran-release.p12 \
  --alias aaris-quran-release \
  --password-file /private/path/keystore-password.txt \
  --output /private/output/Aaris-Quran-0.3.0-release.apk
```

Keep the signing key and password backup private and reuse the same key for future updates.
The build emits an APK and a verification JSON beside it; it does not create an AAB or run CI.
Do not commit private keys/passwords. The Quran pack is an offline non-commercial preview. Hadith is a separate immutable pack;
no Hadith collection is claimed as installed unless `hadith-manifest.json` and `hadith.sqlite`
are generated from the checked-in, hash-locked source vault.

## Source notices

Quran: Tanzil Project, Uthmani 1.1 — https://tanzil.net/ (original text unchanged).
Word glosses: Data Quran / Hablullah team, collected from Quran.com, pinned mirror commit
023b2f59edcf5cea0f4218a50039c6e6fc7154bc at https://github.com/mamun-al-abdullah/quran.
Those glosses are CC BY-NC-ND 4.0 and keep their original values. This bundled preview is
non-commercial: no paid sales, subscriptions or ads. They are imported source glosses,
not newly authored tafsir or independently reviewed Aaris meanings. Consult original sources.
Font: Amiri Project, SIL OFL 1.1. All notices are available offline inside the app.

## Recovery

Every checkpoint is a normal fast-forward commit. See docs/PROGRESS.md before resuming.
Never erase user learning or rewrite original source files to fix a UI/search issue.
