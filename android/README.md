# Android reader — Phase 1

This module is intentionally small. It is the first mobile slice of the product north star: **Read → get stuck → tap → understand → keep reading.**

Current scope is only the trustworthy **Read** foundation:

- Jetpack Compose UI;
- one-screen Surah reader with 1–114 navigation;
- Arabic rendered only from `quran_ayah.original_text`;
- bundled `quran-core 1.0.2` evidence pack;
- build-time and runtime SHA-256 verification;
- SQLite opened with `OPEN_READONLY`;
- Tanzil source attribution visible from the reader;
- no account, analytics, ads, or Quran API dependency.

The app does **not** invent word meanings or morphology. Word tap remains blocked until a legally preserved word-level source has passed the Source Vault gate.

## Build

The Android build is pinned to AGP 9.4.0, Gradle 9.6.0 in CI, JDK 17, API 37 and Compose BOM 2026.09.00.

From this directory:

```bash
gradle :app:assembleDebug
```

The build fails before compilation if the local `content-packs/quran-core/1.0.2/content.sqlite` bytes do not match that pack's manifest SHA-256.
