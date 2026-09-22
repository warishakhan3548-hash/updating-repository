# Aaris Quran

A calm native Android Quran reader with a private learning ledger and local evidence search.

The front is a quiet Mushaf. The durable foundation is original source text, stable coordinates,
an append-only learning history and rebuildable indexes. AI never supplies scripture or citations.

## Build

Requirements: Python 3.10+, JDK 17, Android SDK 35. No paid service or API key.

```sh
python3 tools/build_content.py
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
source quote. It is not the complete architecture: no Hadith corpus,
reviewed morphology/sense graph, FSRS, audio, ambient overlay or signed pack updater ships yet.

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
