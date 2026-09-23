# Quran isolated word-audio delivery

Aaris keeps the base APK small and never synthesizes Quran pronunciation. Pronunciation uses
**complete human-recorded word clips** from a pinned immutable source.

## Current architecture

The active delivery contract is:

- Source: `zaibihassan/Quranic-Word-By-Word-Audio-Data`
- Immutable revision: `9796e08caae700f44266255da320adf6e5ab4114`
- Style: **Muallim** (teacher / repeat-friendly)
- Format: one complete Ogg/Opus recording per Quran word
- Safe canonical coverage: exactly **77,326 SOURCE_ALIGNED `:W:` word identities**
- Base APK: **no Quran audio bytes**
- Download unit: **one immutable Surah container**
- Playback: one complete isolated source clip, from its own start to natural completion
- Full-Surah timestamp slicing: **forbidden**

This directly fixes boundary artifacts such as a word beginning with the end of the previous word
or being cut before its own ending. Aaris no longer seeks into one continuous recitation for
word-tap pronunciation.

## Why one Surah container?

The upstream source has 77,000+ individual files. Downloading those one-by-one on a phone would
create excessive HTTP/file-system overhead. A one-time maintainer packer therefore creates 114
`.aqp` files — one per Surah.

Each `.aqp` contains:

1. a tiny coordinate index,
2. the original isolated Ogg/Opus word clips concatenated **byte-for-byte**.

No clip is transcoded, stretched, trimmed, normalized, merged with a neighbour, or regenerated.

The index maps:

`ayah + word position -> payload offset + exact clip length`

Android uses `MediaPlayer.setDataSource(FileDescriptor, offset, length)` so the selected byte
range is already one complete Ogg stream. Playback starts at zero for that clip and finishes on
the clip's own completion event. There is no `seekTo()` and no guessed stop timer.

## AQP v1

Container contract:

```
magic      "AARISQW1\n"
uint32be   index byte length
index      UTF-8 TSV: ayah<TAB>position<TAB>payload_offset<TAB>length
payload    complete source .opus files concatenated in Quran coordinate order
```

The per-Surah SHA-256 and exact byte size live in the generated
`app/src/main/assets/quran-audio-word-catalog.json`. That catalog is tiny metadata and may be
inside the APK. The `.aqp` binaries themselves are never APK assets.

## User flow

- Reader screen: **Audio ↓** downloads only that Surah.
- Settings: **Quran audio · Download All** downloads all 114 Surah containers.
- Downloads are explicit user actions only.
- Interrupted downloads keep a revision-scoped partial file and use HTTP Range resume.
- A pack becomes playable only after exact size, SHA-256, index, coverage and Ogg-boundary checks.
- After installation, word tap and the ambient recall overlay both use the same local isolated clip.
- If a Surah is not installed, Quran reading/meaning/learning/recall still work; pronunciation
  stays silent until the user chooses to download it.

## Build/runtime boundaries

Normal Gradle and direct release builds never acquire audio. Build guards fail if any
`.aqp`, `.opus`, `.pb` or legacy `.pack` pronunciation binary appears inside app assets.

The one-time maintainer packer is:

`tools/build_word_audio_surah_packs.py`

It is not a Gradle task. It binds the upstream audio to the stable semantic Quran word identity
hash rather than raw SQLite serialization bytes.

The old monolithic vendoring command is retired and intentionally fail-fast.

## Source / rights note

The upstream dataset metadata declares Apache-2.0. Aaris currently treats this as a
non-commercial preview pending an independent recording-rights review before commercial
distribution.
