# Offline Quran word-audio vault

Aaris treats pronunciation audio exactly like other immutable source content: **acquire once,
verify, commit locally, then build/runtime never fetch it from the web**.

## Active pack

When present, this directory is bundled as Android assets:

`source-vault/quran-audio/active/quran-audio/`

The required manifest is:

`source-vault/quran-audio/active/quran-audio/manifest.json`

Word files use canonical coordinates:

`quran-audio/word/002/002_255_010.opus` = `Q:2:255:W:10`

Prefatory Bismillah IDs (`:B:`) are deliberately not guessed or shifted onto word-audio
coordinates. If a canonical mapping is not exact, Aaris stays silent for that target.

## One-time acquisition

The helper in `tools/acquire_quran_word_audio.py` is an **explicit source acquisition tool**, not
a build task. It refuses a floating dataset revision and requires an immutable 40-hex revision.

The initial supported source layout is the Muallim/Mujawwad word-audio dataset published as
`zaibihassan/Quranic-Word-By-Word-Audio-Data`. Its dataset page declares Apache-2.0 and documents
complete 114-surah `SURAH_AYAH_WORD` OPUS files. Keep the pinned upstream README/license evidence
inside the generated pack and review the source rights before redistribution.

Typical flow:

1. Generate canonical Quran SQLite locally: `python3 tools/build_content.py`
2. Acquire a reviewed, pinned dataset snapshot:
   `python3 tools/acquire_quran_word_audio.py --revision <40-hex-commit>`
3. Run the network-free verifier:
   `python3 tools/check_quran_audio.py --source source-vault/quran-audio/active --quran-db app/src/main/assets/quran.sqlite`
4. Commit the generated active pack using Git LFS.

After step 4, a fresh checkout can build pronunciation audio from repository-local bytes. Gradle
does not call Hugging Face, Quran.com, Sunnah.com, a CDN, or any other content website.

## Runtime behavior

The APK never has an online fallback. If the verified pack is bundled, tapping a canonical Quran
word plays its local clip while the existing meaning UI opens. The same process-wide player is used
by the timed overlay recall card. If the pack is absent or a target is not canonically addressable,
meaning/learning still work and audio simply stays unavailable.
