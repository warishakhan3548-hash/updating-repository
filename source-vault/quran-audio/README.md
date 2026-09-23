# Offline Quran word-audio vault

Aaris treats pronunciation audio exactly like other immutable source content: **acquire once,
verify, commit locally, then build/runtime never fetch it from the web**.

## Active pack

When present, this directory is bundled as Android assets:

`source-vault/quran-audio/active/quran-audio/`

The required manifest is:

`source-vault/quran-audio/active/quran-audio/manifest.json`

Release availability is tracked separately in:

`source-vault/quran-audio/release-policy.json`

While the large vendor import has never completed, that policy is `pending_vendor_import` and a
build remains fully offline with pronunciation disabled. `tools/complete_quran_audio_pack.py`
changes it to `required` only after the exact local pack passes full verification, pinning the
manifest SHA-256 and pack ID. From then on deleting/replacing the local audio causes a build failure;
there is never a network reacquisition fallback.

Word clips use canonical coordinates, but Aaris does **not** ship 77k individual APK assets.
The one-time packer content-addresses every clip by SHA-256, stores byte-identical pronunciations
only once, and writes the unique audio into small seekable chunk packs plus a compact SQLite index.

For example, `Q:2:255:W:10` keeps its canonical Word ID while `quran-audio/index.sqlite` records
the exact chunk ID, byte offset and byte length containing its pronunciation. Another occurrence
with identical audio bytes may safely point at that same immutable range.

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

Fast path for maintainers:

`python3 tools/complete_quran_audio_pack.py`

This is the **single authoritative** one-time acquisition/finalization command. It is never
referenced by Gradle. It refuses to replace an existing active pack unless the maintainer
deliberately passes `--replace`, and performs a conservative 2 GiB free-space preflight before
downloading/staging the pinned snapshot.

Before acquiring the large source snapshot, the packer/verifier can be tested completely offline:

`python3 tools/selftest_quran_audio_pack.py`

The self-test builds a tiny synthetic pack, verifies it, then corrupts it and requires fail-closed rejection.

Typical flow:

1. Generate canonical Quran SQLite locally: `python3 tools/build_content.py`
2. Acquire the pinned reviewed snapshot:
   `python3 tools/acquire_quran_word_audio.py`
   A source update must be explicit and reviewable: update `source-vault/quran-audio/source-lock.json` (repo/revision/license/style/hash/count) first; the acquisition helper does not follow a floating branch.
3. Run the network-free verifier:
   `python3 tools/check_quran_audio.py --source source-vault/quran-audio/active --quran-db app/src/main/assets/quran.sqlite --source-lock source-vault/quran-audio/source-lock.json`
4. Finalize the verified local pack and arm deletion safety:
   `python3 tools/finalize_quran_audio_policy.py`
   This step performs no network access; it re-verifies the pack and pins its exact manifest hash
   and pack ID in `release-policy.json`.
5. Commit the generated active pack as ordinary Git files (deduplicated `.pack` chunks +
   index/manifest/license metadata) together with the updated `release-policy.json`.

After step 5, a normal fresh checkout contains the pronunciation bytes directly; no Git LFS pull is required. Each content-addressed chunk is capped at 32 MiB and the total audio payload at 650 MiB so ordinary Git remains inside the reviewed storage envelope. Gradle
does not call Hugging Face, Quran.com, Sunnah.com, a CDN, or any other content website.

## Runtime behavior

The APK never has an online fallback. If the verified pack is bundled, tapping a canonical Quran
word looks up its verified chunk + byte range in the local index and plays that slice while the existing meaning UI opens. The same process-wide player is used
by the timed overlay recall card. If the pack is absent or a target is not canonically addressable,
meaning/learning still work and audio simply stays unavailable.
