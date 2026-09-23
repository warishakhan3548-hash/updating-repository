# Offline Quran word-audio vault

Aaris treats pronunciation audio exactly like other immutable source content: **acquire once,
verify, commit locally, then build/runtime never fetch it from the web**.

## Active pack

When present, this directory is bundled as Android assets:

`source-vault/quran-audio/active/quran-audio/`

The required manifest is:

`source-vault/quran-audio/active/quran-audio/manifest.json`

Word clips use canonical coordinates, but Aaris does **not** ship 77k individual APK assets.
The one-time packer concatenates them into exactly 114 Surah pack files plus a compact SQLite index:

`Q:2:255:W:10` is stored as a byte range inside `quran-audio/packs/002.pack`, with the exact range recorded in `quran-audio/index.sqlite`.

Prefatory Bismillah IDs (`:B:`) and Quran words whose meaning/source alignment is currently
`UNMAPPED` are deliberately not guessed or shifted onto audio coordinates. The active pack covers
only `SOURCE_ALIGNED` canonical `:W:` identities; if alignment is not exact, Aaris stays silent.

Current canonical counts are intentionally explicit:

- Quran reader tokens: 77,881 total.
- Prefatory `:B:` tokens: 440 in the current canonical build; these are excluded from word-audio coordinates.
- Canonical `:W:` tokens: 77,441.
- The 9 fail-closed unaligned ayat contain 115 `:W:` tokens.
- Therefore the current safe audio target is exactly **77,326 SOURCE_ALIGNED `:W:` identities**.

The acquisition preflight compares those identities against the pinned upstream snapshot before
downloading, and the local pack verifier repeats the identity/range checks before Android packaging.

## One-time acquisition

The helper in `tools/acquire_quran_word_audio.py` is an **explicit source acquisition tool**, not
a build task. Its default source is pinned to the reviewed immutable dataset commit
`9796e08caae700f44266255da320adf6e5ab4114`; it never follows a moving `main` implicitly.

The initial supported source layout is the Muallim/Mujawwad word-audio dataset published as
`zaibihassan/Quranic-Word-By-Word-Audio-Data`. Its dataset page declares Apache-2.0 and documents
complete 114-surah `SURAH_AYAH_WORD` OPUS files. Keep the pinned upstream README/license evidence
inside the generated pack and review the source rights before redistribution.

Typical flow:

1. Generate canonical Quran SQLite locally: `python3 tools/build_content.py`
2. Acquire the pinned reviewed snapshot:
   `python3 tools/acquire_quran_word_audio.py`
   A source update must be explicit and reviewable: update `source-vault/quran-audio/source-lock.json` (repo/revision/license/style/hash/count) first; the acquisition helper does not follow a floating branch.
3. Run the network-free verifier:
   `python3 tools/check_quran_audio.py --source source-vault/quran-audio/active --quran-db app/src/main/assets/quran.sqlite`
4. Commit the generated active pack as ordinary Git files (114 `.pack` files + index/manifest/license metadata).

After step 4, a normal fresh checkout contains the pronunciation bytes directly; no Git LFS pull is required. Gradle
does not call Hugging Face, Quran.com, Sunnah.com, a CDN, or any other content website.

## Runtime behavior

The APK never has an online fallback. If the verified pack is bundled, tapping a canonical Quran
word looks up its verified byte range in the local index and plays that slice from the local Surah pack while the existing meaning UI opens. The same process-wide player is used
by the timed overlay recall card. If the pack is absent or a target is not canonically addressable,
meaning/learning still work and audio simply stays unavailable.
