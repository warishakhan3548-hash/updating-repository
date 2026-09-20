# Phase 1 Reader Architecture

The Phase 1 reader is deliberately smaller than the eventual comprehension engine. Its job is to prove the product's most important trust path:

preserved Quran source → verified content pack → read-only local database → original Arabic on screen

## Current reader boundary

The Android app packages the repository's quran-core 1.0.3 directory directly as a development asset. It does not download Quran text at runtime and it does not request Internet access.

At first use, QuranPackStore:

1. reads the bundled pack manifest;
2. requires the expected Quran pack identity and 6,236-record contract;
3. copies the SQLite artifact into noBackupFilesDir;
4. checks the compiled-in expected source ID/version/source SHA-256 and exact 1.0.3 runtime-pack SHA-256;
5. verifies the bundled source-derived attribution notice SHA-256;
6. copies the SQLite bytes only after those pins match, then verifies the copied database SHA-256;
7. opens the verified database read-only;
8. queries only quran_ayah.original_text for display.

Search-normalized Quran fields are not part of the reader rendering path.

The runtime SQLite copy is replaceable content. Personal learning data remains a separate user.sqlite concern.

## Candidate-pack rule

quran-core 1.0.3 is still marked candidate and unsigned. The reader may use it for development and verification, but this work does not promote it to a release-approved content pack and does not invent signing material.

Production distribution remains blocked on the real review/signing policy. The compiled-in development pins are a fail-closed integrity control for this exact unsigned candidate; they are not a substitute for the future signed content-update chain.

## Reader interaction

The initial visible surface is intentionally simple:

- Quran title;
- previous / current Surah / next;
- vertically scrolling source Arabic;
- unobtrusive Tanzil source attribution.

Material controls provide standard touch semantics and target sizing. Quran text is explicitly laid out RTL while app navigation remains stable. The app follows system light/dark appearance and Android font scaling.

## Word-tap boundary

Word tap is not implemented by splitting Quran text on whitespace.

A meaningful tap target must eventually be backed by a legally preserved token/morphology/gloss source with stable TokenID / SegmentID mappings. Until that source passes the Source Vault gate, inventing token boundaries or meanings would weaken the Evidence Plane.

The next safe reader milestone is source-backed token anchoring, not UI-only pseudo-tokenization.

## Privacy and network

The manifest requests no Internet, location, account, analytics or advertising permissions. Android automatic backup is disabled for this development reader. A future user-data backup feature must be explicit, versioned, encrypted where appropriate, and separate from replaceable content packs.
