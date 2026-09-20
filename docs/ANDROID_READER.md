# Android Reader — Phase 1 Vertical Slice

This module is the first visible projection of the existing trusted Reader Core contract, not a second content system.

## Scope

The screen only:

1. opens the already-built `quran-core` pack locally;
2. renders `quran_ayah.original_text`;
3. navigates Surahs with obvious previous/next controls plus a direct 1–114 chooser;
4. performs UI-only tap hit testing for future verified word details.

There is no network permission, account, analytics SDK, translation guess, morphology guess, or AI call.

## Content activation

The Android build points its asset source directly at `content-packs/quran-core/1.1.0/`; no second Quran database is committed.

Gradle hashes `content.sqlite` before every Android build. At first runtime use the asset is copied into `noBackupFilesDir`, hashed again, and opened with Android SQLite `OPEN_READONLY`.

Debug builds may exercise the candidate pack. Release builds fail closed unless the manifest is `approved` **and** the authoritative Python pack gate succeeds. The release task verifies Source Vault/canonical binding, file and semantic integrity, and the Ed25519 signature against `policy/trusted_pack_keys.json`; signature-shaped metadata alone is never treated as verification.

For release environments, install the pinned verifier dependency first with `python -m pip install -r requirements-ci.txt`. If Python is not named `python3`, Gradle accepts `-PpythonExecutable=<path>`.

Runtime also rejects a manifest that was not marked release-ready at build time. The build-time cryptographic gate remains the authoritative approval boundary for official artifacts.

## Runtime architecture

`ReaderScreen -> ReaderViewModel -> QuranRepository -> PackagedQuranRepository -> read-only content.sqlite`

Only `ayah_id`, `surah`, `ayah`, and `original_text` enter the UI model. Search-normalized columns do not.

## Tap boundary

`SurfaceTapAnchorResolver` mirrors the existing Reader Core's ephemeral `ui-surface:` contract. It returns display-character offsets only. It does not create or persist TokenID, LexemeID, lemma, root, sense, grammar, or meaning.

Until a legally preserved word-level source passes the Source Vault gate, authoritative word details remain withheld.

## Accessibility

Primary navigation controls have at least 48dp interactive height. The current Surah label is also an obvious button that opens a dismissible 1–114 chooser, avoiding dozens of repeated taps without introducing unverified Surah-name content. Quran text uses content-driven RTL direction, each ayah has a screen-reader description with its coordinate, safe drawing insets are respected, and navigation never depends on a gesture.

## Build toolchain

Pinned as of 2026-09-20:

- Android Gradle Plugin 9.4.1
- Gradle 9.6.1 in CI
- Kotlin/Compose compiler plugin 2.4.20
- Compose BOM 2026.04.01 (Compose 1.11-era stable baseline compatible with compileSdk 36)
- compile/target SDK 36
- minimum SDK 24

## Current limitation

The UI uses the device Arabic font. A bundled Quran font will only be added after its exact artifact, licence, provenance and redistribution rights are preserved under project control and rendering is regression-tested.

## Release rollback state

Debug builds may exercise unsigned candidate packs and do not write production rollback state.

For a non-debug release, the build-time pack gate remains authoritative for source/provenance/semantic/signature approval. At runtime the reader additionally requires a positive signed `release_sequence`, remembers the highest accepted sequence together with the exact pack SHA-256 under `noBackupFilesDir/content/activation/`, and rejects both lower-sequence rollback and reuse of one sequence for different bytes.

The state and installed pack replacement use Android `AtomicFile` so interrupted replacement falls back to the prior complete file rather than leaving a partial trust record or content database. This is an installed-app rollback barrier, not hardware-backed monotonic storage: uninstall or clear-data removes the state. Automatic downloaded content updates remain disabled.