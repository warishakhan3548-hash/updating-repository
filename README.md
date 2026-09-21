# Aaris Shield

Aaris Shield is an Android, local-first safety project intended to reduce exposure to sexually explicit content while minimizing false positives on ordinary people and non-sexual contexts.

The repository is developed through small numbered upgrades. Step 1 established the architecture foundation. Step 2 adds a functional local DNS/domain shield through Android `VpnService`; visual classification, screen observation, blur overlays, OCR filtering, and audio filtering are not implemented yet.

## Current verification

Run the focused Step 2 pure-Kotlin verification without building an APK:

```bash
bash ./tools/verify-network.sh
```

CI additionally runs Android unit tests for `:core:foundation` and `:core:network` plus `:app:compileDebugKotlin`. Full APK build verification remains reserved for Step 18.

See `AARIS_SHIELD_PROGRESS.md` for step state, `docs/ARCHITECTURE.md` for subsystem boundaries, and `docs/NETWORK_SHIELD.md` for Step 2 behavior and platform limitations.
