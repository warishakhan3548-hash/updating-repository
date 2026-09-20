# Android Reader — Phase 1

The Android reader is a thin local presentation adapter over the trusted Quran Reader Core contract. It does not create a second Quran database or a second evidence model.

## Current boundary

- Pack: `quran-core@1.0.4`.
- Pack status: `candidate`; debug validation is allowed, production release is blocked.
- The existing pack directory is mounted into Android assets at build time. The SQLite file is not duplicated in source control.
- Runtime activation verifies manifest identity, pack SHA-256, Tanzil notice SHA-256 and embedded SQLite metadata.
- The database is opened with `SQLiteDatabase.OPEN_READONLY`.
- Reader queries project only `original_text`; search-normalized columns are not displayed.
- There is no `INTERNET` permission, account, analytics SDK, or live Quran API on the critical read path.
- The exact source notice remains available in the UI. Opening Tanzil is an explicit external-browser action.
- Word meanings and morphology are intentionally absent until a word-level source independently passes the Source Vault and licence gates.

## UI

The first screen is deliberately small:

1. Quran title and Source action.
2. Previous / Choose Surah / Next controls with 48dp minimum targets.
3. Source-faithful Arabic ayahs in RTL.
4. Fail-closed verification screen if local evidence cannot be verified.

Surah numbers are used without inventing an additional unprovenanced metadata dataset. A trusted Surah metadata/name source can be added later as its own content assertion.

## Build

The project is standalone under `apps/android-reader/`.

CI pins AGP 9.4.0, Gradle 9.6.0, JDK 17, Compose BOM 2026.09.00 and immutable full-SHA GitHub Actions. It builds and unit-tests the debug reader only while the content pack remains a candidate.

A release build must remain blocked until the pinned Quran pack is reviewed, signed and promoted according to the repository release policy.
