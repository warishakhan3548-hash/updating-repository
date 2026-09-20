# Android Reader — Phase 1 Vertical Slice

This module is the first visible projection of the existing trusted Reader Core contract, not a second content system.

## Scope

The screen only:

1. opens the already-built `quran-core` pack locally;
2. renders `quran_ayah.original_text`;
3. navigates Surahs with obvious previous/next controls;
4. performs UI-only tap hit testing for future verified word details.

There is no network permission, account, analytics SDK, translation guess, morphology guess, or AI call.

## Content activation

The Android build points its asset source directly at `content-packs/quran-core/1.0.4/`; no second Quran database is committed.

Gradle hashes `content.sqlite` before every Android build. At first runtime use the asset is copied into `noBackupFilesDir`, hashed again, and opened with Android SQLite `OPEN_READONLY`.

Debug builds may exercise the candidate pack. Release builds fail closed while the pack is a candidate. For an `approved` pack, Gradle invokes the repository content-pack gate, which performs Source Vault, semantic and trusted-key cryptographic verification before release packaging. Signature-shaped metadata alone is never treated as verification. Runtime also rejects every non-release-ready pack outside debug builds.

## Runtime architecture

`ReaderScreen -> ReaderViewModel -> QuranRepository -> PackagedQuranRepository -> read-only content.sqlite`

Only `ayah_id`, `surah`, `ayah`, and `original_text` enter the UI model. Search-normalized columns do not.

## Tap boundary

`SurfaceTapAnchorResolver` mirrors the existing Reader Core's ephemeral `ui-surface:` contract. It returns display-character offsets only. It does not create or persist TokenID, LexemeID, lemma, root, sense, grammar, or meaning.

Until a legally preserved word-level source passes the Source Vault gate, authoritative word details remain withheld.

## Accessibility

Primary navigation controls have at least 48dp interactive height. Quran text uses content-driven RTL direction, each ayah has a screen-reader description with its coordinate, safe drawing insets are respected, and navigation never depends on a gesture.

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


## Release verifier prerequisite

The release gate uses the pinned Python security adapter in `requirements-foundation.txt`. Build environments that intentionally produce release artifacts must install that file first. Debug Android builds do not need the verifier package.

No production public key is enrolled today, so the current candidate remains deliberately non-releaseable. Future downloaded pack updates will need a native Android signature verifier and persisted anti-rollback sequence; the current build-time gate protects only content bundled into a signed APK.
